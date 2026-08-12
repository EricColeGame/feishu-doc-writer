#!/usr/bin/env bash
# 稳定的飞书文档写入脚本 - 两阶段提交 + checkpoint 恢复
# Usage: ./write-valid-doc.sh <result_file> [checkpoint_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/feishu-api.sh"
source "${SCRIPT_DIR}/lib/checkpoint.sh"

# 飞书文档访问域名必须使用租户专属域名，例如 your-tenant.feishu.cn。
FEISHU_DOC_DOMAIN="${FEISHU_DOC_DOMAIN:?Set FEISHU_DOC_DOMAIN to your tenant document domain}"

RESULT_FILE="${1:-}"
CHECKPOINT_FILE="${2:-}"
CANDIDATE_INFO_FILE="${3:-}"
JUDGMENT_FILE="${4:-}"
KEYWORD_SCREENSHOT_FILE="${5:-}"

RESUME_PHASE2=false
for arg in "$@"; do
  [ "$arg" = "--resume-phase2" ] && RESUME_PHASE2=true
done

MAX_KEYWORDS_PER_BATCH=2
MAX_CHARS_PER_BATCH=7000

log() {
  echo "[write-valid-doc] $*" >&2
}

json_error() {
  local msg="$1"
  jq -nc --arg error "$msg" '{status:"error",error:$error}'
  exit 1
}

sanitize_keyword_slug() {
  local keyword="$1"
  local slug
  # LC_ALL=C 强制 sed 在 C locale 处理：使 [^a-z0-9] 严格匹配 ASCII，
  # 重音字符（如 ō）的 UTF-8 多字节被当非 ASCII 替换为 _，与 KD 预过滤的 jq gsub + keyword-screenshot.sh 行为一致；
  # 否则 en_US.UTF-8 下 sed 的 [a-z] 保留 ō → slug 与截图/KD 不匹配 → 图片插不上 / kd=-2 绕过 KD≤10 预过滤（2026-08-12 09时段踩坑）
  slug="$(echo "${keyword}" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  if [ -z "${slug}" ]; then
    slug="keyword_unknown"
  fi
  echo "${slug}"
}

# topic_type 英文→中文映射：候选词文件存英文（ChatGPT 分类输出），valid 文档展示中文。
map_topic_type_zh() {
  case "$1" in
    person) echo "人物" ;;
    game) echo "游戏" ;;
    movie) echo "电影" ;;
    tv) echo "电视剧" ;;
    anime) echo "动漫" ;;
    product) echo "产品" ;;
    sports) echo "体育" ;;
    music) echo "音乐" ;;
    book) echo "图书" ;;
    software) echo "软件" ;;
    ai_tool) echo "AI工具" ;;
    science) echo "科技" ;;
    event) echo "事件" ;;
    organization) echo "机构" ;;
    place) echo "地名" ;;
    other) echo "其他" ;;
    "") echo "未知" ;;
    *) echo "$1" ;;
  esac
}

is_cjk_keyword() {
  local keyword="$1"
  echo "$keyword" | python3 -c "import sys,re; print('yes' if re.search(r'[\u4e00-\u9fff\u3400-\u4dbf]', sys.stdin.read()) else 'no')"
}

is_keyword_roblox() {
  local keyword="$1"
  if [ -z "$CANDIDATE_INFO_FILE" ] || [ ! -f "$CANDIDATE_INFO_FILE" ]; then
    echo "unknown"
    return
  fi
  local kw_lower
  kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
  local val
  val=$(jq -r --arg kw "$kw_lower" '.candidate_keywords[] | select((.name | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) == ($kw | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))) | .is_roblox // false' "$CANDIDATE_INFO_FILE" 2>/dev/null || echo "false")
  [ -z "$val" ] && val="false"
  echo "$val"
}

get_keyword_category() {
  local keyword="$1"
  # 中文关键词跳过
  if [ "$(is_cjk_keyword "$keyword")" = "yes" ]; then
    echo "skip"
    return
  fi
  if [ -z "$JUDGMENT_FILE" ] || [ ! -f "$JUDGMENT_FILE" ]; then
    echo "stable"
    return
  fi
  local kw_norm
  # 用 jq 标准化（ascii_downcase + gsub），与下方 .judgment / .categories 匹配侧（行115）及
  # get_is_roblox（行87）完全同款，避免 tr/sed 在 UTF-8 locale 下保留重音字符导致两侧不一致
  # （典型反例：César Gastélum 经 tr/sed 仍是 "césar gastélum"，而 jq 侧为 "c sar gast lum"，
  # 带重音词匹配失败被错误降级为 stable）
  kw_norm=$(jq -nr --arg kw "$keyword" '$kw | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | gsub("^ +| +$"; "")')

  # 优先读取 .judgment[]；若缺少兼容字段或未命中，再回退到 .categories。
  if jq -e '.judgment | type == "array"' "$JUDGMENT_FILE" >/dev/null 2>&1; then
    if jq -e --arg kw "$kw_norm" '.judgment[] | select((((.keyword // "") | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | gsub("^ +| +$"; "")) == $kw) and (((.decision // "") == "steep") or (.is_steep_rise == true)))' "$JUDGMENT_FILE" >/dev/null 2>&1; then
      echo "steep"
      return
    fi
  fi

  # categories.steep 支持字符串数组或 dict 数组（{keyword, reason}）
  if jq -e --arg kw "$kw_norm" '.categories.steep // [] | map((if type=="object" then (.keyword // "") else . end) | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | gsub("^ +| +$"; "")) | index($kw)' "$JUDGMENT_FILE" >/dev/null 2>&1; then
    echo "steep"
    return
  fi

  echo "stable"
}

get_category_keywords() {
  local category="$1"
  shift
  local all_keywords=("$@")
  local matched=()
  for kw in "${all_keywords[@]}"; do
    local result_json block_downstream kept_in_filtered
    result_json="$(get_result_json_by_keyword "$kw")"
    kept_in_filtered="$(jq -r --arg kw "$kw" 'if (.keywords | type) == "array" and (.keywords | length) > 0 then ((.keywords | index($kw)) != null) else "fallback" end' "$RESULT_FILE" 2>/dev/null || echo "fallback")"
    if [ "$kept_in_filtered" = "false" ]; then
      continue
    fi
    if [ "$kept_in_filtered" != "true" ]; then
      block_downstream="$(jq -r '.trends_gate.block_downstream // false' <<<"$result_json" 2>/dev/null || echo "false")"
      [ "$block_downstream" = "true" ] && continue
    fi
    if [ "$(get_keyword_category "$kw")" = "$category" ]; then
      matched+=("$kw")
    fi
  done
  printf '%s\n' "${matched[@]}"
}

get_result_json_by_keyword() {
  local keyword="$1"
  jq -c --arg kw "$keyword" '.results[] | select(.keyword == $kw)' "$RESULT_FILE"
}

get_keyword_last_day_sort_value() {
  local keyword="$1"
  local result_json value
  result_json="$(get_result_json_by_keyword "$keyword")"
  [ -z "$result_json" ] && echo "" && return
  value="$(jq -r 'if .last_day_value != null then .last_day_value elif (.trends_data | type)=="object" then (.trends_data.last_day.keyword // "") else "" end' <<<"$result_json")"
  if [ "$value" = "null" ]; then
    value=""
  fi
  echo "$value"
}

sort_keywords_by_recommendation_and_last_day() {
  local keywords=("$@")
  local entries=()
  local idx=0
  local kw rec rank raw_value sort_value

  for kw in "${keywords[@]}"; do
    rec="medium"
    if [ -n "$CANDIDATE_INFO_FILE" ] && [ -f "$CANDIDATE_INFO_FILE" ]; then
      local kw_lower
      kw_lower=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
      rec=$(jq -r --arg kw "$kw_lower" '.candidate_keywords[] | select((.name | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) == ($kw | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))) | .recommendation // "medium"' "$CANDIDATE_INFO_FILE" 2>/dev/null || echo "medium")
      [ -z "$rec" ] && rec="medium"
    fi

    case "$rec" in
      high) rank=0 ;;
      medium) rank=1 ;;
      low) rank=2 ;;
      *) rank=1 ;;
    esac

    raw_value="$(get_keyword_last_day_sort_value "$kw")"
    if [ -n "$raw_value" ]; then
      sort_value=$(printf '%010d' "$raw_value")
    else
      sort_value="-000000001"
    fi

    entries+=("${rank}|${sort_value}|$(printf '%06d' "$idx")|${kw}")
    idx=$((idx + 1))
  done

  if [ ${#entries[@]} -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1n -k2,2r -k3,3n | while IFS='|' read -r _ _ _ keyword; do
    printf '%s\n' "$keyword"
  done
}

generate_keyword_block() {
  local result_json="$1"

  local keyword slug domains trends_url search_url wiki_url
  keyword=$(echo "$result_json" | jq -r '.keyword')
  slug=$(sanitize_keyword_slug "$keyword")

  # 生成域名列表（UTC 时间转换为上海时间）
  # 白名单：新词报告只展示 .wiki/.com/.org/.net 四种后缀；wiki.wiki、.online 等一律不展示。
  # 注：whois 仍照常检验所有后缀（generate_domain_combinations 未变，F0 建站选域名仍会用到 .online 等结果）。
  # 排除 wiki.wiki 类是因为 animewiki.wiki 也以 .wiki 结尾，不能只靠 endswith(.wiki) 判断。
  domains=$(echo "$result_json" | jq -r '.domains[] | select(((.domain // "") | endswith("wiki.wiki") | not) and (((.domain // "") | endswith(".wiki")) or ((.domain // "") | endswith(".com")) or ((.domain // "") | endswith(".org")) or ((.domain // "") | endswith(".net")))) |
    "- \(.domain) (\(.status)" +
    (if .status == "registered" then " | registrar: \(.registrar) | created: \(.creation_date)" else "" end) +
    ")"' | python3 -c "
import sys, re
from datetime import datetime, timezone, timedelta
for line in sys.stdin:
    line = line.rstrip('\n')
    def convert(m):
        ts = m.group(1)
        try:
            dt = datetime.fromisoformat(ts.rstrip('Z')).replace(tzinfo=timezone.utc)
            sh = dt + timedelta(hours=8)
            return 'created: ' + sh.strftime('%Y-%m-%d %H:%M 上海时间')
        except:
            return m.group(0)
    line = re.sub(r'created: (\d{4}-\d{2}-\d{2}T[\d:]+Z?)', convert, line)
    sys.stdout.write(line + '\n')
" | sed 's/^/  /')

  trends_url=$(echo "$result_json" | jq -r '.trends_url')
  search_url=$(echo "$result_json" | jq -r '.search_url')
  wiki_url=$(echo "$result_json" | jq -r '.wiki_search_url')

  local video_count_display
  video_count_display=$(echo "$result_json" | jq -r '.video_count_text // ""')
  if [ -z "$video_count_display" ]; then
    video_count_display="未获取"
  fi

  local kd_display
  kd_display="未获取"
  if [ -n "$KEYWORD_SCREENSHOT_FILE" ] && [ -f "$KEYWORD_SCREENSHOT_FILE" ]; then
    local kd_val
    # 先尝试整文件解析（兼容多行 pretty-print JSON），失败再 fallback 到 tail -1（混有日志行的文件）
    kd_val=$(jq -r --arg slug "$slug" '.kd_data[$slug] // empty' "$KEYWORD_SCREENSHOT_FILE" 2>/dev/null || \
             tail -1 "$KEYWORD_SCREENSHOT_FILE" | jq -r --arg slug "$slug" '.kd_data[$slug] // empty' 2>/dev/null || \
             true)
    [ -n "$kd_val" ] && [ "$kd_val" != "null" ] && kd_display="$kd_val"
  fi

  # 从候选词信息文件查找结构化数据
  local is_roblox_display="未知" recommendation_display="未知" release_date_display="未知" trend_reason_display="未知" topic_type_display="未知"
  if [ -n "$CANDIDATE_INFO_FILE" ] && [ -f "$CANDIDATE_INFO_FILE" ]; then
    local kw_lower
    kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
    local candidate_info
    candidate_info=$(jq --arg kw "$kw_lower" '.candidate_keywords[] | select((.name | ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) == ($kw | gsub("[^a-z0-9 ]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")))' "$CANDIDATE_INFO_FILE" 2>/dev/null || true)
    if [ -n "$candidate_info" ]; then
      local is_roblox_val
      is_roblox_val=$(echo "$candidate_info" | jq -r '.is_roblox // false')
      if [ "$is_roblox_val" = "true" ]; then
        is_roblox_display="是"
      else
        is_roblox_display="否"
      fi
      recommendation_display=$(echo "$candidate_info" | jq -r '.recommendation // "未知"')
      release_date_display=$(echo "$candidate_info" | jq -r '.release_date // "未知"')
      trend_reason_display=$(echo "$candidate_info" | jq -r 'if .trend_reason // "" | . | length > 0 then .trend_reason else "未知" end')
      local topic_type_raw
      topic_type_raw=$(echo "$candidate_info" | jq -r 'if .topic_type // "" | . | length > 0 then .topic_type else "" end')
      topic_type_display="$(map_topic_type_zh "$topic_type_raw")"
    fi
  fi

  # 趋势原因/类型仅在 SHOW_TREND_REASON_TYPE=1 时展示；默认关闭，避免 trends-daily-pipeline（游戏词）
  # 等共用此脚本的 pipeline 因缺少 topic_type 字段而展示"趋势词类型：未知"
  local trend_meta=""
  if [ "${SHOW_TREND_REASON_TYPE:-0}" = "1" ]; then
    trend_meta=$'\n- 趋势原因：'"${trend_reason_display}"$'\n- 趋势词类型：'"${topic_type_display}"
  fi

  cat <<EOF
### ${keyword}

#### 1) 域名可用性
${domains}

#### 2) 基本信息
- 是否 Roblox 游戏：${is_roblox_display}
- 发布日期：${release_date_display}
- 推荐度：${recommendation_display}${trend_meta}
- 一周内视频数量：${video_count_display}
- KD：${kd_display}

#### 3) 链接信息
- Trends URL: ${trends_url}
- Search URL: ${search_url}
- Wiki URL: ${wiki_url}

#### 4) 图片 - Trends

[[IMG_TRENDS_${slug}]]

#### 5) 图片 - SEO关键词工具

[[IMG_KEYWORD_${slug}]]

#### 6) 图片 - Search

[[IMG_SEARCH_${slug}]]

#### 7) 图片 - Wiki

[[IMG_WIKI_${slug}]]

---

EOF
}

write_with_retry() {
  local token="$1"
  local doc_token="$2"
  local content="$3"
  local max_retries=3

  for attempt in $(seq 1 $max_retries); do
    if append_content "$token" "$doc_token" "$content"; then
      return 0
    fi

    log "WARN: append failed, attempt $attempt/$max_retries"

    if [ $attempt -lt $max_retries ]; then
      sleep $((attempt * 2))
    fi
  done

  return 1
}

write_single_keyword() {
  local token="$1"
  local doc_token="$2"
  local keyword="$3"

  local result_json
  result_json=$(jq --arg kw "$keyword" '.results[] | select(.keyword == $kw)' "$RESULT_FILE")
  local block
  block=$(generate_keyword_block "$result_json")

  # 尝试写入完整块
  if write_with_retry "$token" "$doc_token" "$block"; then
    return 0
  fi

  log "ERROR: failed to write keyword: $keyword"
  return 1
}

write_batch() {
  local token="$1"
  local doc_token="$2"
  shift 2
  local keywords=("$@")

  local batch_content=""
  for kw in "${keywords[@]}"; do
    local result_json
    result_json=$(jq --arg kw "$kw" '.results[] | select(.keyword == $kw)' "$RESULT_FILE")
    batch_content+=$(generate_keyword_block "$result_json")
  done

  # 检查大小
  if [ ${#batch_content} -gt $MAX_CHARS_PER_BATCH ]; then
    log "WARN: batch too large (${#batch_content} chars), downgrade to single keyword"
    return 1
  fi

  write_with_retry "$token" "$doc_token" "$batch_content"
}

process_single_doc() {
  local token="$1"
  local run_id="$2"
  local title_suffix="$3"
  local checkpoint_file="$4"
  local resume_phase2="$5"
  shift 5
  local filter_keywords=("$@")

  local total_keywords=${#filter_keywords[@]}
  local total_images=$((total_keywords * 4))

  # 排除中文词
  local unique_keywords=0 skipped_cjk=0
  for kw in "${filter_keywords[@]}"; do
    if [ "$(is_cjk_keyword "$kw")" = "yes" ]; then
      skipped_cjk=$((skipped_cjk + 1))
    else
      unique_keywords=$((unique_keywords + 1))
    fi
  done
  local unique_images=$((unique_keywords * 4))
  if [ "$skipped_cjk" -gt 0 ]; then
    log "[$title_suffix] Filtered $skipped_cjk CJK keywords, effective unique: $unique_keywords"
  fi

  if [ "$unique_keywords" -eq 0 ]; then
    log "[$title_suffix] No keywords to process, skipping"
    echo ""
    return 0
  fi

  log "[$title_suffix] Processing: $total_keywords keywords, $total_images images"

  # 初始化或加载 checkpoint
  if [ -z "$checkpoint_file" ] || [ ! -f "$checkpoint_file" ]; then
    local checkpoint_id default_checkpoint_file
    checkpoint_id="${run_id}_${title_suffix}"
    if [ -n "$checkpoint_file" ]; then
      checkpoint_id="$(basename "$checkpoint_file" .json)"
    fi
    default_checkpoint_file="${CHECKPOINT_DIR}/${checkpoint_id}.json"

    if [ "$resume_phase2" = true ] && [ -f "$default_checkpoint_file" ]; then
      checkpoint_file="$default_checkpoint_file"
      log "[$title_suffix] Resuming from inferred checkpoint: $checkpoint_file"
    else
      checkpoint_file=$(init_checkpoint "$checkpoint_id" "$total_keywords" "$total_images")
      log "[$title_suffix] Created checkpoint: $checkpoint_file"
    fi
  else
    log "[$title_suffix] Resuming from checkpoint: $checkpoint_file"
  fi

  # 获取或创建文档
  local doc_token doc_url
  doc_token=$(get_checkpoint_doc_token "$checkpoint_file")

  if [ -z "$doc_token" ]; then
    log "[$title_suffix] Creating new document..."
    local doc_title="Trends Valid 验证结果 - ${run_id} (${title_suffix})"
    doc_token=$(create_document "$token" "$doc_title") || { log "ERROR: failed to create document for $title_suffix"; return 1; }
    doc_url="https://${FEISHU_DOC_DOMAIN}/docx/${doc_token}"
    update_doc_info "$checkpoint_file" "$doc_token" "$doc_url"
    log "[$title_suffix] Document created: $doc_url"
  else
    doc_url="https://${FEISHU_DOC_DOMAIN}/docx/${doc_token}"
    log "[$title_suffix] Using existing document: $doc_url"
    ensure_document_public_access "$token" "$doc_token" || { log "ERROR: failed to ensure public access for existing document: $doc_url"; return 1; }
  fi

  # 如果 checkpoint 已标记为 done，默认直接返回缓存结果；但 --resume-phase2 时允许继续补图。
  local checkpoint_status
  checkpoint_status=$(jq -r '.status // "writing"' "$checkpoint_file")
  if [ "$checkpoint_status" = "done" ] && [ "$resume_phase2" != true ]; then
    log "[$title_suffix] Already completed (checkpoint=done), returning cached result"
    local remaining_ckpt replaced_ckpt
    remaining_ckpt=$(jq -r '.phase.image_inserting.remaining_placeholders // 0' "$checkpoint_file")
    replaced_ckpt=$(jq -r '.phase.image_inserting.replaced_images // 0' "$checkpoint_file")
    jq -nc \
      --arg status "$([ "${remaining_ckpt}" -eq 0 ] && echo "success" || echo "partial")" \
      --arg doc_token "$doc_token" \
      --arg doc_url "$doc_url" \
      --argjson written_kw "$unique_keywords" \
      --argjson total_img "$total_images" \
      --argjson replaced_img "${replaced_ckpt}" \
      --argjson remaining "${remaining_ckpt}" \
      --arg checkpoint "$checkpoint_file" \
      '{status:$status, doc_token:$doc_token, doc_url:$doc_url, written_keywords:$written_kw, total_images:$total_img, replaced_images:$replaced_img, remaining_placeholders:$remaining, checkpoint_file:$checkpoint}'
    return 0
  fi

  local keyword_count=""

  if [ "$resume_phase2" = true ]; then
    log "[$title_suffix] Resuming directly to Phase 2 (--resume-phase2)"
  else
    # ========== 阶段 1：正文写入（分类只用于排序，不写大层级标题） ==========
    log "[$title_suffix] Phase 1: Writing keywords..."

    local keyword_index=0

    local category_order=("steep" "stable")

    for cat_idx in 0 1; do
      local cat="${category_order[$cat_idx]}"

      local cat_keywords=()
      for kw in "${filter_keywords[@]}"; do
        if [ "$(get_keyword_category "$kw")" = "$cat" ]; then
          cat_keywords+=("$kw")
        fi
      done

      if [ ${#cat_keywords[@]} -eq 0 ]; then
        log "[$title_suffix] Skip empty category: $cat"
        continue
      fi

      mapfile -t cat_keywords < <(sort_keywords_by_recommendation_and_last_day "${cat_keywords[@]}")
      log "[$title_suffix] Sorted $cat keywords: ${cat_keywords[*]}"

      for keyword in "${cat_keywords[@]}"; do
        if is_keyword_written "$checkpoint_file" "$keyword"; then
          log "[$title_suffix] Skip already written: $keyword"
          continue
        fi

        if write_single_keyword "$token" "$doc_token" "$keyword"; then
          mark_keyword_written "$checkpoint_file" "$keyword" "$keyword_index"
          log "[$title_suffix] ✓ Written: $keyword [$cat]"
          keyword_index=$((keyword_index + 1))
          sleep 1
        else
          log "[$title_suffix] ✗ Failed: $keyword"
        fi
      done
    done

    # ========== 阶段 1.5：完整性校验 ==========
    # 若 checkpoint 已进入 image_inserting 或 done 阶段，跳过完整性校验（部分图片已替换）
    if [ "$checkpoint_status" = "image_inserting" ] || [ "$checkpoint_status" = "done" ]; then
      log "[$title_suffix] Phase 1.5: Skipped (checkpoint phase=$checkpoint_status, images partially replaced)"
    else
      log "[$title_suffix] Phase 1.5: Verifying completeness..."
      sleep 5

      local blocks_json placeholder_count
      blocks_json=$(list_all_blocks "$token" "$doc_token")
      keyword_count=$(count_keyword_titles "$blocks_json")
      placeholder_count=$(count_placeholders "$blocks_json" "[[IMG_")

      log "[$title_suffix] Verification: keywords=$keyword_count/$unique_keywords, placeholders=$placeholder_count/$unique_images"

      if [ "$keyword_count" -lt "$unique_keywords" ] || [ "$placeholder_count" -lt "$unique_images" ]; then
        log "[$title_suffix] ERROR: Completeness check failed"
        echo ""
        return 1
      fi
    fi
  fi

  update_phase "$checkpoint_file" "image_inserting"

  # 预提取 keyword screenshot JSON：优先解析整个文件；若前面混有日志，再回退到最后一行。
  local keyword_screenshots_json=""
  if [ -n "$KEYWORD_SCREENSHOT_FILE" ] && [ -f "$KEYWORD_SCREENSHOT_FILE" ]; then
    keyword_screenshots_json=$(jq -c '.' "$KEYWORD_SCREENSHOT_FILE" 2>/dev/null || true)
    if [ -z "$keyword_screenshots_json" ]; then
      keyword_screenshots_json=$(tail -1 "$KEYWORD_SCREENSHOT_FILE")
    fi
  fi

  # ========== 阶段 2：图片替换 ==========
  log "[$title_suffix] Phase 2: Replacing images..."

  local success=0 failed=0 blocks_json=""

  for kw in "${filter_keywords[@]}"; do
    local result
    result=$(jq -c --arg kw "$kw" '.results[] | select(.keyword == $kw)' "$RESULT_FILE")
    [ -z "$result" ] && continue

    local keyword slug
    keyword=$(echo "$result" | jq -r '.keyword')
    slug=$(sanitize_keyword_slug "$keyword")

    # 收集待处理的 (img_type, placeholder, local_path) 三元组
    local -a pending_types=() pending_placeholders=() pending_paths=()
    for img_type in trends keyword search wiki; do
      local upper placeholder local_path
      upper=$(echo "$img_type" | tr '[:lower:]' '[:upper:]')
      placeholder="[[IMG_${upper}_${slug}]]"
      if [ "$img_type" = "keyword" ]; then
        local_path=""
        if [ -n "$keyword_screenshots_json" ]; then
          local_path=$(echo "$keyword_screenshots_json" | jq -r --arg slug "$slug" '.screenshots[$slug] // empty')
        fi
      else
        local_path=$(echo "$result" | jq -r --arg t "$img_type" '(.screenshots[$t] | if type == "object" then .local_path else . end) // empty')
      fi

      if is_placeholder_replaced "$checkpoint_file" "$placeholder"; then
        log "[$title_suffix] Skip already replaced: $placeholder"
        success=$((success + 1))
        continue
      fi

      if [ -z "$local_path" ] || [ ! -f "$local_path" ]; then
        log "[$title_suffix] WARN: image missing: $placeholder -> $local_path"
        failed=$((failed + 1))
        continue
      fi

      pending_types+=("$img_type")
      pending_placeholders+=("$placeholder")
      pending_paths+=("$local_path")
    done

    [ ${#pending_placeholders[@]} -eq 0 ] && continue

    # ===== 优化：本关键词 N 张图 upload 并发 =====
    # 步骤：先串行 list_all_blocks + create_image_block（需要 block_id 才能 upload 绑定 parent_node）
    # 然后 N 张图 upload 并发拿 file_token，最后串行 bind + delete
    local -a block_ids=() parent_ids=() parent_indices=() file_tokens=()
    local list_ok=true
    local i
    for i in "${!pending_placeholders[@]}"; do
      local ph="${pending_placeholders[$i]}"
      blocks_json=$(list_all_blocks "$token" "$doc_token")
      local paragraph_id
      paragraph_id=$(find_placeholder_paragraph "$blocks_json" "$ph")
      if [ -z "$paragraph_id" ]; then
        log "[$title_suffix] WARN: placeholder not found: $ph"
        block_ids+=("")
        parent_ids+=("")
        parent_indices+=("")
        failed=$((failed + 1))
        continue
      fi
      local parent_and_index pid pidx
      parent_and_index=$(find_parent_and_index "$blocks_json" "$paragraph_id")
      pid="${parent_and_index%%|*}"
      pidx="${parent_and_index##*|}"
      if [ -z "$pid" ] || ! [[ "$pidx" =~ ^[0-9]+$ ]]; then
        log "[$title_suffix] ERROR: invalid parent/index for $ph"
        block_ids+=("")
        parent_ids+=("")
        parent_indices+=("")
        failed=$((failed + 1))
        continue
      fi
      local bid
      bid=$(create_image_block_after_paragraph "$token" "$doc_token" "$pid" "$pidx" || true)
      if [ -z "$bid" ]; then
        log "[$title_suffix] ERROR: failed to create image block for $ph"
        block_ids+=("")
        parent_ids+=("")
        parent_indices+=("")
        failed=$((failed + 1))
        continue
      fi
      block_ids+=("$bid")
      parent_ids+=("$pid")
      parent_indices+=("$pidx")
    done

    # 并发 upload (drive 端点 5 QPS 独立额度)
    local upload_dir
    upload_dir=$(mktemp -d)
    for i in "${!pending_placeholders[@]}"; do
      local bid="${block_ids[$i]}"
      [ -z "$bid" ] && continue
      local path="${pending_paths[$i]}"
      (
        local ft
        ft=$(upload_media_get_token "$token" "$bid" "$path" || true)
        echo "$ft" > "${upload_dir}/token_${i}.txt"
      ) &
    done
    wait

    # 读回 file_token，先串行 bind（按 block_id 不受 index 影响）
    for i in "${!pending_placeholders[@]}"; do
      local ph="${pending_placeholders[$i]}"
      local bid="${block_ids[$i]}"
      [ -z "$bid" ] && continue
      local ft=""
      [ -f "${upload_dir}/token_${i}.txt" ] && ft=$(cat "${upload_dir}/token_${i}.txt")
      if [ -z "$ft" ]; then
        log "[$title_suffix] ERROR: failed to upload image for $ph"
        failed=$((failed + 1))
        block_ids[$i]=""
        continue
      fi
      if ! bind_image_token_to_block "$token" "$doc_token" "$bid" "$ft"; then
        log "[$title_suffix] ERROR: failed to bind image for $ph"
        failed=$((failed + 1))
        block_ids[$i]=""
        continue
      fi
    done

    # delete placeholder：重新 list 获取 fresh index（多次 create 已让存储 index 过期）
    # 从后往前删，避免 index 偏移
    blocks_json=$(list_all_blocks "$token" "$doc_token")
    local -a del_list=()
    for i in "${!pending_placeholders[@]}"; do
      local ph="${pending_placeholders[$i]}"
      local bid="${block_ids[$i]}"
      [ -z "$bid" ] && continue
      local fresh_pid fresh_pair fpid fpidx
      fresh_pid=$(find_placeholder_paragraph "$blocks_json" "$ph")
      if [ -z "$fresh_pid" ]; then
        log "[$title_suffix] WARN: placeholder disappeared during delete phase: $ph"
        mark_image_replaced "$checkpoint_file" "$ph"
        success=$((success + 1))
        log "[$title_suffix] ✓ Replaced: $ph"
        continue
      fi
      fresh_pair=$(find_parent_and_index "$blocks_json" "$fresh_pid")
      fpid="${fresh_pair%%|*}"
      fpidx="${fresh_pair##*|}"
      del_list+=("${fpidx}|${fpid}|${ph}")
    done

    # 按 index 降序排序
    local IFS_BAK="$IFS"
    IFS=$'\n' del_list=($(printf '%s\n' "${del_list[@]}" | sort -t'|' -k1 -n -r))
    IFS="$IFS_BAK"

    for entry in "${del_list[@]}"; do
      local fpidx="${entry%%|*}"
      local rest="${entry#*|}"
      local fpid="${rest%%|*}"
      local ph="${rest#*|}"
      delete_paragraph_by_index "$token" "$doc_token" "$fpid" "$fpidx" || true
      mark_image_replaced "$checkpoint_file" "$ph"
      success=$((success + 1))
      log "[$title_suffix] ✓ Replaced: $ph"
    done
    rm -rf "$upload_dir"
  done

  # ========== 最终验证 ==========
  log "[$title_suffix] Final verification..."
  sleep 3

  blocks_json=$(list_all_blocks "$token" "$doc_token")
  local remaining
  remaining=$(count_placeholders "$blocks_json" "[[IMG_")

  if [ -z "${keyword_count:-}" ]; then
    keyword_count=$(count_keyword_titles "$blocks_json")
  fi

  update_phase "$checkpoint_file" "done"

  # 输出单文档结果 JSON（不换行，供 main 捕获）
  jq -nc \
    --arg status "$([ "$remaining" -eq 0 ] && echo "success" || echo "partial")" \
    --arg doc_token "$doc_token" \
    --arg doc_url "$doc_url" \
    --argjson written_kw "${keyword_count:-0}" \
    --argjson total_img "$total_images" \
    --argjson replaced_img "$success" \
    --argjson remaining "$remaining" \
    --arg checkpoint "$checkpoint_file" \
    '{status:$status, doc_token:$doc_token, doc_url:$doc_url, written_keywords:$written_kw, total_images:$total_img, replaced_images:$replaced_img, remaining_placeholders:$remaining, checkpoint_file:$checkpoint}'

  if [ "$remaining" -eq 0 ]; then
    log "[$title_suffix] ✅ Success: All content written and images replaced"
  else
    log "[$title_suffix] ⚠️  Partial success: $remaining placeholders remaining"
  fi
}

main() {
  if [ -z "${RESULT_FILE}" ]; then
    json_error "usage: ./write-valid-doc.sh <result_file> [checkpoint_file] [candidate_info_file] [judgment_file]"
  fi

  if [ ! -f "${RESULT_FILE}" ]; then
    json_error "result_file not found: ${RESULT_FILE}"
  fi

  local run_id result_parent_dir result_date_tag
  run_id=$(basename "$RESULT_FILE" .json)
  result_parent_dir=$(basename "$(dirname "$RESULT_FILE")")
  if [[ "$result_parent_dir" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
    result_date_tag="$result_parent_dir"
    run_id="${run_id}_${result_date_tag}"
  fi

  # 获取 token
  local token
  token=$(get_feishu_token) || json_error "failed to get feishu token"

  # 读取所有关键词
  local all_keywords=()
  mapfile -t all_keywords < <(jq -r '.results[].keyword' "$RESULT_FILE")

  # 按 is_roblox 分组
  local roblox_keywords=() non_roblox_keywords=()
  local can_split=false

  if [ -n "$CANDIDATE_INFO_FILE" ] && [ -f "$CANDIDATE_INFO_FILE" ]; then
    can_split=true
    for kw in "${all_keywords[@]}"; do
      if [ "$(is_keyword_roblox "$kw")" = "true" ]; then
        roblox_keywords+=("$kw")
      else
        non_roblox_keywords+=("$kw")
      fi
    done
    log "Split: ${#roblox_keywords[@]} Roblox, ${#non_roblox_keywords[@]} non-Roblox"
  fi

  if [ "$can_split" = true ] && [ ${#roblox_keywords[@]} -gt 0 ] && [ ${#non_roblox_keywords[@]} -gt 0 ]; then
    # ====== 分两个文档 ======
    log "Creating two documents: Roblox + non-Roblox"

    local roblox_result="" non_roblox_result=""
    local roblox_ckpt="${CHECKPOINT_DIR}/${run_id}_Roblox.json"
    local non_roblox_ckpt="${CHECKPOINT_DIR}/${run_id}_非Roblox.json"

    # 并行处理两文档（两个独立 doc，飞书 per-doc 配额独立；app 级 3 QPS 由重试机制消化）
    local out_dir
    out_dir=$(mktemp -d)
    (
      process_single_doc "$token" "$run_id" "Roblox" "$roblox_ckpt" "$RESUME_PHASE2" "${roblox_keywords[@]}" > "${out_dir}/roblox.json"
    ) &
    local roblox_pid=$!
    (
      process_single_doc "$token" "$run_id" "非Roblox" "$non_roblox_ckpt" "$RESUME_PHASE2" "${non_roblox_keywords[@]}" > "${out_dir}/non_roblox.json"
    ) &
    local non_roblox_pid=$!

    wait "$roblox_pid" || true
    wait "$non_roblox_pid" || true

    roblox_result=$(cat "${out_dir}/roblox.json" 2>/dev/null || echo "")
    non_roblox_result=$(cat "${out_dir}/non_roblox.json" 2>/dev/null || echo "")
    rm -rf "$out_dir"

    # 组合输出
    local overall_status="success"
    if echo "$roblox_result" | jq -e 'select(.status != "success")' >/dev/null 2>&1 || \
       echo "$non_roblox_result" | jq -e 'select(.status != "success")' >/dev/null 2>&1; then
      overall_status="partial"
    fi

    jq -nc \
      --arg status "$overall_status" \
      --argjson roblox "${roblox_result:-null}" \
      --argjson non_roblox "${non_roblox_result:-null}" \
      '{
        status: $status,
        docs: {
          roblox: $roblox,
          non_roblox: $non_roblox
        }
      }'
  else
    # ====== 单文档（无候选词文件或所有词都是同一类） ======
    local target_keywords=("${all_keywords[@]}")
    local suffix="all"

    if [ "$can_split" = true ]; then
      if [ ${#roblox_keywords[@]} -gt 0 ]; then
        suffix="Roblox"
        target_keywords=("${roblox_keywords[@]}")
      else
        suffix="非Roblox"
        target_keywords=("${non_roblox_keywords[@]}")
      fi
    fi

    local result
    result=$(process_single_doc "$token" "$run_id" "$suffix" "$CHECKPOINT_FILE" "$RESUME_PHASE2" "${target_keywords[@]}")

    if [ -n "$result" ]; then
      # 兼容旧格式输出
      echo "$result" | jq '{
        status: .status,
        doc_token: .doc_token,
        doc_url: .doc_url,
        summary: {
          total_keywords: .written_keywords,
          written_keywords: .written_keywords,
          total_images: .total_images,
          replaced_images: .replaced_images,
          remaining_placeholders: .remaining_placeholders
        },
        checkpoint_file: .checkpoint_file
      }'
    fi
  fi
}

main
