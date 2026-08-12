#!/usr/bin/env bash
# 飞书 API 封装函数库

APP_ID="${FEISHU_APP_ID:?Set FEISHU_APP_ID before using feishu-doc-writer}"
APP_SECRET="${FEISHU_APP_SECRET:?Set FEISHU_APP_SECRET before using feishu-doc-writer}"

log() {
  echo "[feishu-api] $*" >&2
}

get_feishu_token() {
  local payload response code msg token attempt
  payload="$(jq -nc --arg app_id "${APP_ID}" --arg app_secret "${APP_SECRET}" '{app_id:$app_id, app_secret:$app_secret}')"
  # 偶发网络瞬断会导致首次 curl 返回空（2026-07-10 18点 F3.1 踩过），加 1 次重试兜底
  code="1"
  for attempt in 1 2; do
    response="$(curl -sS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "${payload}" 2>/dev/null || true)"
    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    [ "${code}" = "0" ] && break
    [ "${attempt}" = "1" ] && sleep 2
  done
  msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
  if [ "${code}" != "0" ]; then
    log "ERROR: token request failed after retry: code=${code} msg=${msg}"
    return 1
  fi

  token="$(echo "${response}" | jq -r '.tenant_access_token // empty' 2>/dev/null || true)"
  [ -n "${token}" ] || return 1
  echo "${token}"
}

ensure_document_public_access() {
  local token="$1"
  local doc_token="$2"
  local response code msg attempt verify_response verify_code
  local verify_external verify_share verify_link

  local payload
  payload='{"type":"docx","external_access":true,"share_entity":"anyone","link_share_entity":"anyone_readable"}'

  attempt=0
  local max_attempts=5
  while [ $attempt -lt $max_attempts ]; do
    response="$(curl -sS --max-time 30 -X PATCH "https://open.feishu.cn/open-apis/drive/v1/permissions/${doc_token}/public?type=docx" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "${payload}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "${code}" = "0" ]; then
      break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      log "WARN: set public access failed (attempt ${attempt}/${max_attempts}): code=${code} msg=${msg}, retry in ${backoff}s"
      sleep $backoff
    fi
  done
  if [ "${code}" != "0" ]; then
    log "ERROR: set public access failed after ${max_attempts} attempts: code=${code} msg=${msg}"
    return 1
  fi

  attempt=0
  while [ $attempt -lt $max_attempts ]; do
    verify_response="$(curl -sS --max-time 30 "https://open.feishu.cn/open-apis/drive/v1/permissions/${doc_token}/public?type=docx" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)"

    verify_code="$(echo "${verify_response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    if [ "${verify_code}" = "0" ]; then
      verify_external="$(echo "${verify_response}" | jq -r '.data.permission_public.external_access // false' 2>/dev/null || echo false)"
      verify_share="$(echo "${verify_response}" | jq -r '.data.permission_public.share_entity // ""' 2>/dev/null || echo "")"
      verify_link="$(echo "${verify_response}" | jq -r '.data.permission_public.link_share_entity // ""' 2>/dev/null || echo "")"
      if [ "${verify_external}" = "true" ] && [ "${verify_share}" = "anyone" ] && [ "${verify_link}" = "anyone_readable" ]; then
        return 0
      fi
      msg="external_access=${verify_external} share_entity=${verify_share} link_share_entity=${verify_link}"
    else
      msg="$(echo "${verify_response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      log "WARN: verify public access failed (attempt ${attempt}/${max_attempts}): code=${verify_code} ${msg}, retry in ${backoff}s"
      sleep $backoff
    fi
  done

  log "ERROR: verify public access failed after ${max_attempts} attempts: code=${verify_code} ${msg}"
  return 1
}

create_document() {
  local token="$1"
  local title="$2"
  local response code msg doc_token

  local payload
  payload=$(jq -nc --arg title "$title" '{
    title: $title
  }')

  local attempt=0
  local max_attempts=5
  while [ $attempt -lt $max_attempts ]; do
    response="$(curl -sS --max-time 30 -X POST "https://open.feishu.cn/open-apis/docx/v1/documents" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "${payload}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "${code}" = "0" ]; then
      break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      log "WARN: create document failed (attempt ${attempt}/${max_attempts}): code=${code} msg=${msg}, retry in ${backoff}s"
      sleep $backoff
    fi
  done
  if [ "${code}" != "0" ]; then
    log "ERROR: create document failed after ${max_attempts} attempts: code=${code} msg=${msg}"
    return 1
  fi

  doc_token="$(echo "${response}" | jq -r '.data.document.document_id // empty' 2>/dev/null || true)"
  [ -n "${doc_token}" ] || return 1
  ensure_document_public_access "${token}" "${doc_token}" || return 1
  echo "${doc_token}"
}

get_page_id() {
  local token="$1"
  local doc_token="$2"
  local response code page_id attempt msg

  for attempt in 1 2 3; do
    response="$(curl -sS --connect-timeout 10 --max-time 30 \
      "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks?page_size=1" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "${code}" = "0" ]; then
      page_id="$(echo "${response}" | jq -r '.data.items[0].block_id // empty' 2>/dev/null || true)"
      if [ -n "${page_id}" ]; then
        echo "${page_id}"
        return 0
      fi
      msg="empty page_id"
    fi

    if [ "${attempt}" -lt 3 ]; then
      log "WARN: get page_id failed (attempt ${attempt}/3): code=${code} msg=${msg}, retry in 2s"
      sleep 2
    fi
  done

  log "ERROR: get page_id failed after 3 attempts: code=${code} msg=${msg}"
  return 1
}

build_text_elements_json() {
  local text="$1"
  local bold="${2:-false}"

  python3 - "$text" "$bold" <<'PY'
import json
import re
import sys
from urllib.parse import quote

text = sys.argv[1]
bold = sys.argv[2].lower() == 'true'
md_pattern = re.compile(r'\[([^\]]+)\]\((https?://[^\s)]+)\)')
url_pattern = re.compile(r'https?://[^\s]+')
trailing_punct = '.,;:!?)]}>。，；：！？）】》』」'


def style(url=None):
    data = {}
    if bold:
        data['bold'] = True
    if url:
        data['link'] = {'url': quote(url, safe='')}
    return data


def append_text(elements, content, url=None):
    if not content:
        return
    run = {'content': content}
    style_data = style(url)
    if style_data:
        run['text_element_style'] = style_data
    elements.append({'text_run': run})


def split_trailing(url):
    tail = ''
    while url and url[-1] in trailing_punct:
        tail = url[-1] + tail
        url = url[:-1]
    return url, tail


elements = []
pos = 0
while pos < len(text):
    md_match = md_pattern.search(text, pos)
    url_match = url_pattern.search(text, pos)

    match = None
    match_kind = None
    if md_match and url_match:
        if md_match.start() <= url_match.start():
            match = md_match
            match_kind = 'markdown'
        else:
            match = url_match
            match_kind = 'url'
    elif md_match:
        match = md_match
        match_kind = 'markdown'
    elif url_match:
        match = url_match
        match_kind = 'url'
    else:
        append_text(elements, text[pos:])
        break

    append_text(elements, text[pos:match.start()])

    if match_kind == 'markdown':
        label = match.group(1)
        url = match.group(2)
        append_text(elements, label, url=url)
        pos = match.end()
    else:
        raw_url = match.group(0)
        url, tail = split_trailing(raw_url)
        append_text(elements, url, url=url)
        append_text(elements, tail)
        pos = match.start() + len(raw_url)

if not elements:
    append_text(elements, text)

print(json.dumps(elements, ensure_ascii=False))
PY
}

parse_line_to_block() {
  local line="$1"
  local text elements

  # 检测标题级别（从长到短匹配，避免 #### 被 ### 先匹配）
  if [[ "$line" =~ ^####[[:space:]](.+)$ ]]; then
    # H4 → 普通加粗文本 (block_type=2) - 子章节标题，不出现在目录中
    text="${BASH_REMATCH[1]}"
    elements="$(build_text_elements_json "$text" true)"
    jq -nc --argjson elements "$elements" '{
      block_type: 2,
      text: {
        elements: $elements,
        style: {}
      }
    }'
  elif [[ "$line" =~ ^###[[:space:]](.+)$ ]]; then
    # H3 → heading2 (block_type=4) - 关键词标题
    text="${BASH_REMATCH[1]}"
    elements="$(build_text_elements_json "$text" false)"
    jq -nc --argjson elements "$elements" '{
      block_type: 4,
      heading2: {
        elements: $elements
      }
    }'
  elif [[ "$line" =~ ^##[[:space:]](.+)$ ]]; then
    # H2 → heading1 (block_type=3) - 分类标题（飙升/平稳/已做站）
    text="${BASH_REMATCH[1]}"
    elements="$(build_text_elements_json "$text" false)"
    jq -nc --argjson elements "$elements" '{
      block_type: 3,
      heading1: {
        elements: $elements
      }
    }'
  elif [[ "$line" =~ ^#[[:space:]](.+)$ ]]; then
    # H1 → heading1 (block_type=3) - 单井号兜底：执行者误用 # 而非 ## 时也解析为 heading1
    # 背景：2026-07-03 18时段 miner 文档标题用单 # 致 F2 校验 heading1=0（原逻辑不解析单 #，整行落普通文本）
    text="${BASH_REMATCH[1]}"
    elements="$(build_text_elements_json "$text" false)"
    jq -nc --argjson elements "$elements" '{
      block_type: 3,
      heading1: {
        elements: $elements
      }
    }'
  else
    # 普通文本
    elements="$(build_text_elements_json "$line" false)"
    jq -nc --argjson elements "$elements" '{
      block_type: 2,
      text: {
        elements: $elements,
        style: {}
      }
    }'
  fi
}

# 创建飞书原生表格并填充数据
# 参数: token, doc_token, header_json_array, rows_json_array, col_widths_json_array
# header_json_array: '["排名","域名","数据"]'
# rows_json_array: '[["1","example.com","100"],["2","test.com","50"]]'
# col_widths_json_array: '[60,300,100]' (可选)
# 写入单个表格 cell（全局函数，便于并发调用）
# 用法: _feishu_write_table_cell <token> <doc_token> <cell_id> <text> <bold>
# 参数化 token/doc_token（不再依赖闭包），失败返回 1（不 log，由调用方汇总）
_feishu_write_table_cell() {
  local token="$1" doc_token="$2" cid="$3" text="$4" bold="${5:-false}"
  local style="{}"
  local response code msg attempt=0
  local max_attempts=3
  [ "$bold" = "true" ] && style='{"bold":true}'

  while [ $attempt -lt $max_attempts ]; do
    response="$(curl -sS --connect-timeout 10 --max-time 30 -X POST "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${cid}/children" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg t "$text" --argjson s "$style" '{children:[{block_type:2,text:{elements:[{text_run:{content:$t,text_element_style:$s}}],style:{}}}],index:0}')" 2>/dev/null || true)"
    code="$(echo "$response" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "$response" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "$code" = "0" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      sleep $backoff
    fi
  done
  return 1
}

create_table_with_data() {
  local token="$1" doc_token="$2" headers_json="$3" rows_json="$4" col_widths_json="${5:-}"

  local page_id
  page_id=$(get_page_id "$token" "$doc_token") || return 1

  local col_count row_count total_rows
  col_count=$(echo "$headers_json" | jq 'length')
  row_count=$(echo "$rows_json" | jq 'length')
  total_rows=$((row_count + 1))

  # 自动生成 col_widths
  if [ -z "$col_widths_json" ]; then
    col_widths_json=$(python3 -c "import json; print(json.dumps([200]*${col_count}))")
  fi

  # 飞书限制单次最多创建9行
  local init_rows=$total_rows
  [ "$init_rows" -gt 9 ] && init_rows=9

  # 创建初始表格
  local table_resp table_code table_msg table_id
  table_resp="$(curl -sS --connect-timeout 10 --max-time 30 -X POST "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${page_id}/children" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --argjson r "$init_rows" --argjson c "$col_count" --argjson w "$col_widths_json" '{
      children: [{block_type:31, table:{property:{row_size:$r, column_size:$c, column_width:$w}}}],
      index: -1
    }')" 2>/dev/null || true)"
  table_code="$(echo "$table_resp" | jq -r '.code // 1' 2>/dev/null || echo 1)"
  table_msg="$(echo "$table_resp" | jq -r '.msg // ""' 2>/dev/null || echo "")"
  if [ "$table_code" != "0" ]; then
    log "ERROR: create table failed: code=${table_code} msg=${table_msg}"
    return 1
  fi

  table_id=$(echo "$table_resp" | jq -r '.data.children[0].block_id')
  if [ -z "$table_id" ] || [ "$table_id" = "null" ]; then
    log "ERROR: create table failed"
    return 1
  fi

  # 追加剩余行
  local extra=$((total_rows - init_rows))
  for i in $(seq 1 $extra); do
    local row_index=$((init_rows + i - 1))
    local patch_resp patch_code patch_msg attempt=0
    local max_attempts=3

    while [ $attempt -lt $max_attempts ]; do
      patch_resp="$(curl -sS --connect-timeout 10 --max-time 30 -X PATCH "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${table_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"insert_table_row\":{\"row_index\":${row_index}}}" 2>/dev/null || true)"
      patch_code="$(echo "$patch_resp" | jq -r '.code // 1' 2>/dev/null || echo 1)"
      patch_msg="$(echo "$patch_resp" | jq -r '.msg // ""' 2>/dev/null || echo "")"
      if [ "$patch_code" = "0" ]; then
        break
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        # 线性退避(1,2s)替代指数(1,2,4,8,16s)，避免大表格限流时单行退避累积拖垮整体写入
        local backoff=$attempt
        log "WARN: insert table row failed (attempt ${attempt}/${max_attempts}): row_index=${row_index} code=${patch_code} msg=${patch_msg}, retry in ${backoff}s"
        sleep $backoff
      fi
    done

    if [ "$patch_code" != "0" ]; then
      log "ERROR: insert table row failed after ${max_attempts} attempts: row_index=${row_index} code=${patch_code} msg=${patch_msg}"
      return 1
    fi

    # 行间节流从 1s 降到 0.2s：大表格(40+行)写入从 ~40s 降到 ~8s，正常情况无副作用
    sleep 0.2
  done

  # 获取所有 cell IDs
  local block_resp block_code block_msg
  block_resp="$(curl -sS --connect-timeout 10 --max-time 30 "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${table_id}" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)"
  block_code="$(echo "$block_resp" | jq -r '.code // 1' 2>/dev/null || echo 1)"
  block_msg="$(echo "$block_resp" | jq -r '.msg // ""' 2>/dev/null || echo "")"
  if [ "$block_code" != "0" ]; then
    log "ERROR: get table block failed: code=${block_code} msg=${block_msg}"
    return 1
  fi

  local cells_json
  cells_json=$(echo "$block_resp" | jq -c '.data.block.table.cells')

  # 写入表头（串行，单元格少）
  for i in $(seq 0 $((col_count - 1))); do
    local cid htext
    cid=$(echo "$cells_json" | jq -r ".[$i]")
    htext=$(echo "$headers_json" | jq -r ".[$i]")
    _feishu_write_table_cell "$token" "$doc_token" "$cid" "$htext" "true" \
      || { log "ERROR: write header cell failed: ${htext}"; return 1; }
  done

  # 并发写入数据行（信号量限并发，避免飞书 docx 写冲突/限流）
  # 大表格（如 42 行 × 9 列 = 378 cell）串行写入耗时 6-10 分钟且偶发限流雪崩卡死；
  # 改并发后整体耗时降至约 1/并发数。
  local _fail_file
  _fail_file="$(mktemp)"
  : > "$_fail_file"
  local _MAX_PARALLEL=6
  local _running=0
  for r in $(seq 0 $((row_count - 1))); do
    for c in $(seq 0 $((col_count - 1))); do
      local idx=$(( (r + 1) * col_count + c ))
      local cid val
      cid=$(echo "$cells_json" | jq -r ".[$idx]")
      val=$(echo "$rows_json" | jq -r ".[$r][$c]")
      ( _feishu_write_table_cell "$token" "$doc_token" "$cid" "$val" "false" \
          || echo "$idx" >> "$_fail_file" ) &
      _running=$((_running + 1))
      if (( _running >= _MAX_PARALLEL )); then
        wait -n 2>/dev/null || wait
        _running=$((_running - 1))
      fi
    done
  done
  wait
  # 并发写偶发冲突残留的 cell 串行重试一次（并发结束后文档锁竞争消失，串行重试通常成功）。
  # 2026-07-12 验证：50 行表格 6 路并发写偶发 2/450 cell 失败，串行重试后全部恢复。
  if [ -s "$_fail_file" ]; then
    local _retry_count _still_fail=0
    _retry_count=$(wc -l < "$_fail_file" | tr -d ' ')
    log "WARN: ${_retry_count} cells failed concurrently, retrying serially..."
    local fail_idx rr cc rcid rval
    while IFS= read -r fail_idx; do
      [ -z "$fail_idx" ] && continue
      rr=$(( fail_idx / col_count - 1 ))
      cc=$(( fail_idx % col_count ))
      rcid=$(echo "$cells_json" | jq -r ".[$fail_idx]")
      rval=$(echo "$rows_json" | jq -r ".[$rr][$cc]")
      _feishu_write_table_cell "$token" "$doc_token" "$rcid" "$rval" "false" || _still_fail=$((_still_fail + 1))
    done < "$_fail_file"
    if [ "$_still_fail" -gt 0 ]; then
      log "ERROR: ${_still_fail} table cells failed to write (after serial retry)"
      rm -f "$_fail_file"
      return 1
    fi
    log "All ${_retry_count} previously failed cells recovered via serial retry"
  fi
  rm -f "$_fail_file"

  echo "$table_id"
}

append_content() {
  local token="$1"
  local doc_token="$2"
  local content="$3"
  local page_id response code msg

  page_id=$(get_page_id "$token" "$doc_token") || return 1

  # 飞书 API 单次请求限制约 40 个 block，超出返回 99992402。
  # 将内容按行分批（每批最多 40 行）逐批写入。
  local BATCH_SIZE=40
  local lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$content"

  local total=${#lines[@]}
  local i=0
  while [ "$i" -lt "$total" ]; do
    local children='[]'
    local count=0
    while [ "$i" -lt "$total" ] && [ "$count" -lt "$BATCH_SIZE" ]; do
      local line="${lines[$i]}"
      if [ -n "$line" ]; then
        local block
        block=$(parse_line_to_block "$line")
        children=$(echo "$children" | jq --argjson block "$block" '. += [$block]')
        count=$((count + 1))
      fi
      i=$((i + 1))
    done

    if [ "$(echo "$children" | jq 'length')" -eq 0 ]; then
      continue
    fi

    local payload
    payload=$(echo "$children" | jq '{children: ., index: -1}')

    local attempt=0
    local max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
      response="$(curl -sS --max-time 30 -X POST "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${page_id}/children" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "${payload}" 2>/dev/null || true)"

      code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
      msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
      if [ "${code}" = "0" ]; then
        break
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        local backoff=$((2 ** attempt))
        log "WARN: append content failed (attempt ${attempt}/${max_attempts}): code=${code} msg=${msg}, retry in ${backoff}s"
        sleep $backoff
      fi
    done
    if [ "${code}" != "0" ]; then
      log "ERROR: append content failed after ${max_attempts} attempts: code=${code} msg=${msg}"
      return 1
    fi
  done

  return 0
}

list_all_blocks() {
  local token="$1"
  local doc_token="$2"
  local page_token=""
  local has_more="false"
  local code msg
  local resp_file all_file
  # 用临时文件存 response 和累加结果，避免大文档（400+ blocks）response
  # 作命令行参数展开触发 ARG_MAX（2026-07-27 18点 audit 文档 417 blocks 踩过）
  resp_file="$(mktemp)"
  all_file="$(mktemp)"
  printf '%s' '[]' > "${all_file}"

  while :; do
    local url="https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks?page_size=500"
    if [ -n "${page_token}" ]; then
      url="${url}&page_token=${page_token}"
    fi

    local attempt=0
    local max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
      curl -sS --max-time 30 "${url}" -H "Authorization: Bearer ${token}" > "${resp_file}" 2>/dev/null || true
      code="$(jq -r '.code // 1' "${resp_file}" 2>/dev/null || echo 1)"
      msg="$(jq -r '.msg // ""' "${resp_file}" 2>/dev/null || echo "")"
      if [ "${code}" = "0" ]; then
        break
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        local backoff=$((2 ** attempt))
        log "WARN: list blocks failed (attempt ${attempt}/${max_attempts}): code=${code} msg=${msg}, retry in ${backoff}s"
        sleep $backoff
      fi
    done
    if [ "${code}" != "0" ]; then
      log "ERROR: list blocks failed after ${max_attempts} attempts: code=${code} msg=${msg}"
      rm -f "${resp_file}" "${all_file}"
      return 1
    fi

    # 累加本页 items 到 all_file（--slurpfile 从文件读，不经命令行参数，无 ARG_MAX）
    jq -nc --slurpfile resp "${resp_file}" --slurpfile all "${all_file}" \
      '($all[0]) + ($resp[0].data.items // [])' > "${all_file}.tmp" 2>/dev/null && mv "${all_file}.tmp" "${all_file}"

    has_more="$(jq -r '.data.has_more // false' "${resp_file}" 2>/dev/null || echo false)"
    if [ "${has_more}" != "true" ]; then
      break
    fi

    page_token="$(jq -r '.data.page_token // empty' "${resp_file}" 2>/dev/null || true)"
    [ -n "${page_token}" ] || break
  done

  cat "${all_file}"
  rm -f "${resp_file}" "${all_file}" "${all_file}.tmp"
}

count_keyword_titles() {
  local blocks_json="$1"

  # 统计 heading2 (block_type=4) 的数量（关键词标题）
  echo "${blocks_json}" | jq '[
    .[]
    | select(.block_type == 4)
  ] | length'
}

count_placeholders() {
  local blocks_json="$1"
  local pattern="${2:-[[IMG_}"

  echo "${blocks_json}" | jq --arg pattern "$pattern" '[
    .[]
    | select(.block_type == 2)
    | select(
        ([
          (.text.elements[]?.text_run.content // empty),
          (.paragraph.elements[]?.text_run.content // empty)
        ] | join("")) | contains($pattern)
      )
  ] | length'
}

# 提取文档所有 block 的纯文本（每 block 一行，覆盖 text/paragraph/heading1-9/bullet/ordered/quote 所有 text-container 字段）。
# 用途：F2 文档校验 grep 关键标题/Round/路径/"未知"等。feishu docx 各 block_type 字段名不同
# (block_type 2=text→.text, 3-11=heading1-9→.heading1-9, 12=bullet→.bullet, 13=ordered→.ordered, quote→.quote)，
# 只取 .text.elements 会漏 heading，导致标题/Round 文本 grep 为 0（2026-08-09 14时段 F2 校验踩坑）。
extract_all_text() {
  local blocks_json="$1"
  echo "${blocks_json}" | jq -r '
    .[]?
    | [
        (.text.elements[]?.text_run.content // empty),
        (.paragraph.elements[]?.text_run.content // empty),
        (.heading1.elements[]?.text_run.content // empty),
        (.heading2.elements[]?.text_run.content // empty),
        (.heading3.elements[]?.text_run.content // empty),
        (.heading4.elements[]?.text_run.content // empty),
        (.heading5.elements[]?.text_run.content // empty),
        (.heading6.elements[]?.text_run.content // empty),
        (.heading7.elements[]?.text_run.content // empty),
        (.heading8.elements[]?.text_run.content // empty),
        (.heading9.elements[]?.text_run.content // empty),
        (.bullet.elements[]?.text_run.content // empty),
        (.ordered.elements[]?.text_run.content // empty),
        (.quote.elements[]?.text_run.content // empty)
      ] | join("")
  '
}

find_placeholder_paragraph() {
  local blocks_json="$1"
  local placeholder="$2"

  echo "${blocks_json}" | jq -r --arg p "${placeholder}" '
    .[]?
    | select(.block_type==2)
    | select(([
        (.text.elements[]?.text_run.content // empty),
        (.paragraph.elements[]?.text_run.content // empty)
      ] | join("")) | contains($p))
    | .block_id
  ' | head -1
}

find_parent_and_index() {
  local blocks_json="$1"
  local block_id="$2"

  echo "${blocks_json}" | jq -r --arg bid "${block_id}" '
    . as $items
    | ($items[] | select(.block_id==$bid)) as $target
    | ($items[] | select(.block_id==$target.parent_id)) as $parent
    | ($parent.children | to_entries[] | select(.value==$bid) | .key) as $idx
    | "\($target.parent_id)|\($idx)"
  ' | head -1
}

create_image_block_after_paragraph() {
  local token="$1"
  local doc_token="$2"
  local parent_id="$3"
  local paragraph_index="$4"
  local response code msg block_id create_payload

  create_payload="$(jq -nc --argjson idx "$((paragraph_index + 1))" '{children:[{block_type:27,image:{}}],index:$idx}')"

  local attempt=0
  local max_attempts=3
  while [ $attempt -lt $max_attempts ]; do
    response="$(curl -sS --max-time 30 -X POST "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${parent_id}/children" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "${create_payload}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "${code}" = "0" ]; then
      break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      log "WARN: create image block failed (attempt ${attempt}/${max_attempts}): code=${code} msg=${msg}, retry in ${backoff}s"
      sleep $backoff
    fi
  done
  if [ "${code}" != "0" ]; then
    log "ERROR: create image block failed after ${max_attempts} attempts: code=${code} msg=${msg}"
    return 1
  fi

  block_id="$(echo "${response}" | jq -r '.data.children[0].block_id // empty' 2>/dev/null || true)"
  [ -n "${block_id}" ] || return 1
  echo "${block_id}"
}

upload_media_get_token() {
  local token="$1"
  local image_block_id="$2"
  local local_path="$3"
  local size response code msg file_token
  local -a delays=(0 2 5)
  local attempt

  size="$(stat -c%s "${local_path}" 2>/dev/null || echo 0)"
  if [ "${size}" = "0" ]; then
    log "ERROR: invalid file size for ${local_path}"
    return 1
  fi

  for attempt in 1 2 3; do
    response="$(curl -sS -X POST "https://open.feishu.cn/open-apis/drive/v1/medias/upload_all" \
      -H "Authorization: Bearer ${token}" \
      -F "file_name=$(basename "${local_path}")" \
      -F "parent_type=docx_image" \
      -F "parent_node=${image_block_id}" \
      -F "size=${size}" \
      -F "file=@${local_path}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    file_token="$(echo "${response}" | jq -r '.data.file_token // empty' 2>/dev/null || true)"

    if [ "${code}" = "0" ] && [ -n "${file_token}" ]; then
      echo "${file_token}"
      return 0
    fi

    log "WARN: upload_all failed attempt=${attempt} code=${code} msg=${msg}"
    if [ "${attempt}" -lt 3 ]; then
      sleep "${delays[attempt]}"
    fi
  done

  return 1
}

bind_image_token_to_block() {
  local token="$1"
  local doc_token="$2"
  local image_block_id="$3"
  local file_token="$4"
  local response code msg
  local -a delays=(0 2 5)
  local attempt

  for attempt in 1 2 3; do
    response="$(curl -sS -X PATCH "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${image_block_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "$(jq -nc --arg t "${file_token}" '{replace_image:{token:$t}}')" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"

    if [ "${code}" = "0" ]; then
      return 0
    fi

    log "WARN: replace_image failed attempt=${attempt} block=${image_block_id} code=${code} msg=${msg}"
    if [ "${attempt}" -lt 3 ]; then
      sleep "${delays[attempt]}"
    fi
  done

  return 1
}

delete_paragraph_by_index() {
  local token="$1"
  local doc_token="$2"
  local parent_id="$3"
  local paragraph_index="$4"
  local response code msg payload

  payload="$(jq -nc --argjson s "${paragraph_index}" --argjson e "$((paragraph_index + 1))" '{start_index:$s,end_index:$e}')"

  local attempt=0
  local max_attempts=3
  while [ $attempt -lt $max_attempts ]; do
    response="$(curl -sS --max-time 30 -X DELETE "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_token}/blocks/${parent_id}/children/batch_delete" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "${payload}" 2>/dev/null || true)"

    code="$(echo "${response}" | jq -r '.code // 1' 2>/dev/null || echo 1)"
    msg="$(echo "${response}" | jq -r '.msg // ""' 2>/dev/null || echo "")"
    if [ "${code}" = "0" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      local backoff=$((2 ** attempt))
      log "WARN: delete placeholder failed (attempt ${attempt}/${max_attempts}) parent=${parent_id} index=${paragraph_index} code=${code} msg=${msg}, retry in ${backoff}s"
      sleep $backoff
    fi
  done

  log "WARN: delete placeholder failed after ${max_attempts} attempts parent=${parent_id} index=${paragraph_index} code=${code} msg=${msg}"
  return 1
}
