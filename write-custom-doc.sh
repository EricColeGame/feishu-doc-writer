#!/usr/bin/env bash
# 通用飞书文档写入：把 markdown 正文 + 本地图片目录写成一份带图的飞书云文档。
# 复用 lib/feishu-api.sh 的原子能力（不重写 API）。
#
# Usage: write-custom-doc.sh <doc_title> <content_md_file> <image_dir>
#   - content_md_file: markdown 正文，用 ## / ### / #### 标题、[text](url) 链接、
#                      以及形如 [[图片名]] 的占位符（图片名 = 图片文件去扩展名，如 gsc-01）
#   - image_dir: 图片目录，脚本扫描 *.webp / *.png（跳过 _ 开头的分隔图），
#                每张图按文件名生成占位符 [[stem]] 并替换正文里对应占位符
#
# 输出（stdout 最后一行）: {doc_token, doc_url, success, failed, total}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/feishu-api.sh"

# 租户专属域名，例如 your-tenant.feishu.cn。
FEISHU_DOC_DOMAIN="${FEISHU_DOC_DOMAIN:?Set FEISHU_DOC_DOMAIN to your tenant document domain}"

TITLE="${1:-}"
CONTENT_FILE="${2:-}"
IMAGE_DIR="${3:-}"

log() { echo "[write-custom-doc] $*" >&2; }

if [ -z "$TITLE" ] || [ -z "$CONTENT_FILE" ]; then
  echo "usage: $0 <doc_title> <content_md_file> [image_dir]" >&2
  exit 1
fi
# image_dir 为空时（纯文本文档，如 audit/复盘/miner 无图场景）用临时空目录，避免报 usage
_CLEANUP_IMGDIR=false
if [ -z "$IMAGE_DIR" ]; then
  IMAGE_DIR=$(mktemp -d)
  _CLEANUP_IMGDIR=true
fi
if [ ! -f "$CONTENT_FILE" ]; then
  echo "content_md_file not found: $CONTENT_FILE" >&2
  exit 1
fi
if [ ! -d "$IMAGE_DIR" ]; then
  echo "image_dir not found: $IMAGE_DIR" >&2
  exit 1
fi

# ========== 拿 token + 创建文档 ==========
token=$(get_feishu_token) || { echo "FAIL: get_feishu_token" >&2; exit 1; }
log "token ok"

doc_token=$(create_document "$token" "$TITLE") || { echo "FAIL: create_document" >&2; exit 1; }
doc_url="https://${FEISHU_DOC_DOMAIN}/docx/${doc_token}"
log "document created: $doc_url"

# ========== 阶段 1：写正文（含占位符）==========
log "Phase 1: append content ($(wc -l < "$CONTENT_FILE") lines)"
append_content "$token" "$doc_token" "$(cat "$CONTENT_FILE")" || { echo "FAIL: append_content" >&2; exit 1; }
log "content appended, sleep 5s for server settle"
sleep 5

# ========== 阶段 2：扫描图片目录，替换占位符 ==========
mapfile -t IMGS < <(find "$IMAGE_DIR" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) ! -name '_*' | sort)
total=${#IMGS[@]}
log "Phase 2: replace $total images"

success=0
failed=0
for path in "${IMGS[@]}"; do
  stem="$(basename "$path")"; stem="${stem%.*}"
  placeholder="[[${stem}]]"

  blocks_json=$(list_all_blocks "$token" "$doc_token")
  pid=$(find_placeholder_paragraph "$blocks_json" "$placeholder")
  if [ -z "$pid" ]; then
    log "WARN: placeholder not in doc, skip: $placeholder"
    failed=$((failed + 1))
    continue
  fi

  pair=$(find_parent_and_index "$blocks_json" "$pid")
  parent="${pair%%|*}"; idx="${pair##*|}"
  if [ -z "$parent" ] || ! [[ "$idx" =~ ^[0-9]+$ ]]; then
    log "ERROR: bad parent/index for $placeholder"
    failed=$((failed + 1))
    continue
  fi

  bid=$(create_image_block_after_paragraph "$token" "$doc_token" "$parent" "$idx" || true)
  if [ -z "$bid" ]; then log "ERROR: create image block: $placeholder"; failed=$((failed + 1)); continue; fi

  ft=$(upload_media_get_token "$token" "$bid" "$path" || true)
  if [ -z "$ft" ]; then log "ERROR: upload media: $placeholder"; failed=$((failed + 1)); continue; fi

  if ! bind_image_token_to_block "$token" "$doc_token" "$bid" "$ft"; then
    log "ERROR: bind image: $placeholder"
    failed=$((failed + 1))
    continue
  fi

  # 删除占位符段落（重新 list 拿 fresh index）
  blocks_json=$(list_all_blocks "$token" "$doc_token")
  pid=$(find_placeholder_paragraph "$blocks_json" "$placeholder")
  if [ -n "$pid" ]; then
    pair=$(find_parent_and_index "$blocks_json" "$pid")
    parent="${pair%%|*}"; idx="${pair##*|}"
    delete_paragraph_by_index "$token" "$doc_token" "$parent" "$idx" || true
  fi

  success=$((success + 1))
  log "✓ replaced $placeholder ($success/$total)"
done

# 确保文档公开访问（与 write-valid-doc.sh 一致；2026-07-12 补，原需手动兜底）
ensure_document_public_access "$token" "$doc_token" || log "WARN: failed to ensure public access: $doc_url"

# 清理 image_dir 为空时建的临时目录
if $_CLEANUP_IMGDIR; then rm -rf "$IMAGE_DIR"; fi

log "DONE: success=$success failed=$failed total=$total"
jq -nc --arg url "$doc_url" --arg tok "$doc_token" --argjson s "$success" --argjson f "$failed" --argjson t "$total" \
  '{doc_token:$tok, doc_url:$url, success:$s, failed:$f, total:$t}'
