#!/usr/bin/env bash
# write-table-doc.sh - 写入飞书原生表格文档
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="${SKILL_DIR}/tmp"
mkdir -p "$TMP_DIR"

log() {
  echo "[write-table-doc] $*" >&2
}

INPUT_FILE=""
TITLE_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      if [ "$#" -lt 2 ]; then
        echo "Error: --input requires a file path" >&2
        exit 1
      fi
      INPUT_FILE="$2"
      shift 2
      ;;
    --title)
      if [ "$#" -lt 2 ]; then
        echo "Error: --title requires a value" >&2
        exit 1
      fi
      TITLE_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$INPUT_FILE" ]; then
  echo "Error: --input is required" >&2
  exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file does not exist: $INPUT_FILE" >&2
  exit 1
fi

# 检查 JSON 解析
if ! jq empty "$INPUT_FILE" 2>/dev/null; then
  echo "Error: Input file is not valid JSON: $INPUT_FILE" >&2
  exit 1
fi

# 检查 headers
HEADERS_TYPE=$(jq -r '.headers | type' "$INPUT_FILE" 2>/dev/null || echo "null")
if [ "$HEADERS_TYPE" != "array" ]; then
  echo "Error: 'headers' must be an array" >&2
  exit 1
fi

COL_COUNT=$(jq '.headers | length' "$INPUT_FILE")
if [ "$COL_COUNT" -lt 1 ] || [ "$COL_COUNT" -gt 9 ]; then
  echo "Error: 'headers' must be non-empty array with 1 to 9 columns, got: $COL_COUNT" >&2
  exit 1
fi

# 检查 rows
ROWS_TYPE=$(jq -r '.rows | type' "$INPUT_FILE" 2>/dev/null || echo "null")
if [ "$ROWS_TYPE" != "array" ]; then
  echo "Error: 'rows' must be an array" >&2
  exit 1
fi

ROW_VALIDATION=$(jq -r --argjson cols "$COL_COUNT" '
  if all(.rows[]; type == "array" and length == $cols) then
    "valid"
  else
    "invalid"
  end
' "$INPUT_FILE" 2>/dev/null || echo "invalid")

if [ "$ROW_VALIDATION" != "valid" ]; then
  echo "Error: 'rows' must be a 2D array and each row length must match headers ($COL_COUNT)" >&2
  exit 1
fi

TOTAL_ROWS=$(jq '.rows | length' "$INPUT_FILE")

# 检查 col_widths
HAS_WIDTHS=$(jq 'has("col_widths") and (.col_widths != null)' "$INPUT_FILE")
if [ "$HAS_WIDTHS" = "true" ]; then
  WIDTHS_TYPE=$(jq -r '.col_widths | type' "$INPUT_FILE" 2>/dev/null || echo "null")
  if [ "$WIDTHS_TYPE" != "array" ]; then
    echo "Error: 'col_widths' must be an array when provided" >&2
    exit 1
  fi
  WIDTHS_LEN=$(jq '.col_widths | length' "$INPUT_FILE")
  if [ "$WIDTHS_LEN" -ne "$COL_COUNT" ]; then
    echo "Error: 'col_widths' length ($WIDTHS_LEN) must match headers length ($COL_COUNT)" >&2
    exit 1
  fi
fi

# 加载凭据与函数库
if [ -f "${SKILL_DIR}/.env" ]; then
  set -a
  source "${SKILL_DIR}/.env"
  set +a
fi

source "${SKILL_DIR}/lib/feishu-api.sh"

TOKEN=$(get_feishu_token)
if [ -z "$TOKEN" ]; then
  echo "Error: Failed to obtain Feishu tenant access token" >&2
  exit 1
fi

# 确定标题
TITLE="$TITLE_OVERRIDE"
if [ -z "$TITLE" ]; then
  TITLE=$(jq -r '.title // "数据表格文档"' "$INPUT_FILE")
fi

DOC_TOKEN=$(create_document "$TOKEN" "$TITLE")
if [ -z "$DOC_TOKEN" ]; then
  echo "Error: Failed to create document" >&2
  exit 1
fi

# 确保公开访问
if ! ensure_document_public_access "$TOKEN" "$DOC_TOKEN"; then
  echo "Error: Failed to set public access permissions for document: $DOC_TOKEN" >&2
  exit 1
fi

# 获取 page_id
PAGE_ID=$(get_page_id "$TOKEN" "$DOC_TOKEN")
if [ -z "$PAGE_ID" ]; then
  echo "Error: Failed to get page_id for document: $DOC_TOKEN" >&2
  exit 1
fi

# 写入 subtitle（若有）
SUBTITLE=$(jq -r '.subtitle // empty' "$INPUT_FILE")
if [ -n "$SUBTITLE" ]; then
  SUBTITLE_BLOCK=$(jq -nc --arg t "$SUBTITLE" '{
    children: [{
      block_type: 2,
      text: {
        elements: [{
          text_run: {
            content: $t,
            text_element_style: {}
          }
        }],
        style: {}
      }
    }],
    index: -1
  }')

  SUBTITLE_RESP=$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
    "https://open.feishu.cn/open-apis/docx/v1/documents/${DOC_TOKEN}/blocks/${PAGE_ID}/children" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$SUBTITLE_BLOCK" 2>/dev/null || true)

  SUBTITLE_CODE=$(echo "$SUBTITLE_RESP" | jq -r '.code // 1' 2>/dev/null || echo 1)
  if [ "$SUBTITLE_CODE" != "0" ]; then
    echo "Error: Failed to write subtitle block to document: $DOC_TOKEN" >&2
    exit 1
  fi
fi

# 处理列宽配置
if [ "$HAS_WIDTHS" = "true" ]; then
  COL_WIDTHS_JSON=$(jq -c '.col_widths' "$INPUT_FILE")
else
  COL_WIDTHS_JSON=$(jq -nc --argjson c "$COL_COUNT" '[range(0; $c) | 200]')
fi

HEADERS_JSON=$(jq -c '.headers | map(tostring)' "$INPUT_FILE")

# 按每组 8 行数据拆表（表头占 1 行，每张表最多 9 行原生表格）
CHUNK_SIZE=8
TOTAL_CHUNKS=0
if [ "$TOTAL_ROWS" -eq 0 ]; then
  TOTAL_CHUNKS=1
else
  TOTAL_CHUNKS=$(( (TOTAL_ROWS + CHUNK_SIZE - 1) / CHUNK_SIZE ))
fi

for chunk_idx in $(seq 0 $((TOTAL_CHUNKS - 1))); do
  START_ROW=$((chunk_idx * CHUNK_SIZE))
  CHUNK_ROWS_JSON=$(jq -c --argjson s "$START_ROW" --argjson n "$CHUNK_SIZE" '
    .rows[$s : ($s + $n)] | map(map(tostring))
  ' "$INPUT_FILE")
  CHUNK_DATA_ROWS=$(echo "$CHUNK_ROWS_JSON" | jq 'length')
  CHUNK_TOTAL_ROWS=$((CHUNK_DATA_ROWS + 1))
  EXPECTED_CELLS=$(( CHUNK_TOTAL_ROWS * COL_COUNT ))

  # 创建表格原生 Block (block_type: 31)
  CREATE_TABLE_PAYLOAD=$(jq -nc \
    --argjson r "$CHUNK_TOTAL_ROWS" \
    --argjson c "$COL_COUNT" \
    --argjson w "$COL_WIDTHS_JSON" '{
      children: [{block_type: 31, table: {property: {row_size: $r, column_size: $c, column_width: $w}}}],
      index: -1
    }')

  TABLE_RESP=$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
    "https://open.feishu.cn/open-apis/docx/v1/documents/${DOC_TOKEN}/blocks/${PAGE_ID}/children" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$CREATE_TABLE_PAYLOAD" 2>/dev/null || true)

  TABLE_CODE=$(echo "$TABLE_RESP" | jq -r '.code // 1' 2>/dev/null || echo 1)
  if [ "$TABLE_CODE" != "0" ]; then
    echo "Error: Failed to create table block in document: $DOC_TOKEN" >&2
    exit 1
  fi

  TABLE_ID=$(echo "$TABLE_RESP" | jq -r '.data.children[0].block_id // empty' 2>/dev/null || true)
  if [ -z "$TABLE_ID" ]; then
    echo "Error: Table block ID is empty for created table" >&2
    exit 1
  fi

  # 读取表格信息获取 cell IDs
  BLOCK_RESP=$(curl -sS --connect-timeout 10 --max-time 30 \
    "https://open.feishu.cn/open-apis/docx/v1/documents/${DOC_TOKEN}/blocks/${TABLE_ID}" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true)

  BLOCK_CODE=$(echo "$BLOCK_RESP" | jq -r '.code // 1' 2>/dev/null || echo 1)
  if [ "$BLOCK_CODE" != "0" ]; then
    echo "Error: Failed to get table block info for table: $TABLE_ID" >&2
    exit 1
  fi

  CELLS_JSON=$(echo "$BLOCK_RESP" | jq -c '.data.block.table.cells // empty' 2>/dev/null || true)
  ACTUAL_CELLS=$(echo "$CELLS_JSON" | jq 'length' 2>/dev/null || echo 0)

  # 单元格数量校验：必须严格符合 (本表数据行数 + 1) × columns
  if [ "$ACTUAL_CELLS" -ne "$EXPECTED_CELLS" ]; then
    echo "Error: Table cells count mismatch: expected $EXPECTED_CELLS, got $ACTUAL_CELLS" >&2
    exit 1
  fi

  # 写入表头单元格（加粗）
  for c in $(seq 0 $((COL_COUNT - 1))); do
    CID=$(echo "$CELLS_JSON" | jq -r ".[$c]")
    HEADER_TEXT=$(echo "$HEADERS_JSON" | jq -r ".[$c]")
    if ! _feishu_write_table_cell "$TOKEN" "$DOC_TOKEN" "$CID" "$HEADER_TEXT" "true"; then
      echo "Error: Failed to write header cell at column $c" >&2
      exit 1
    fi
  done

  # 写入数据行单元格
  for r in $(seq 0 $((CHUNK_DATA_ROWS - 1))); do
    for c in $(seq 0 $((COL_COUNT - 1))); do
      IDX=$(( (r + 1) * COL_COUNT + c ))
      CID=$(echo "$CELLS_JSON" | jq -r ".[$IDX]")
      CELL_VAL=$(echo "$CHUNK_ROWS_JSON" | jq -r ".[$r][$c]")
      if ! _feishu_write_table_cell "$TOKEN" "$DOC_TOKEN" "$CID" "$CELL_VAL" "false"; then
        echo "Error: Failed to write data cell at row $r, col $c" >&2
        exit 1
      fi
    done
  done
done

DOC_DOMAIN="${FEISHU_DOC_DOMAIN:-open.feishu.cn}"
DOC_URL="https://${DOC_DOMAIN}/docx/${DOC_TOKEN}"

# 成功时标准输出最后一行必须是单行 JSON
jq -nc \
  --arg doc_token "$DOC_TOKEN" \
  --arg doc_url "$DOC_URL" \
  --argjson written_rows "$TOTAL_ROWS" \
  --argjson columns "$COL_COUNT" \
  '{status: "success", doc_token: $doc_token, doc_url: $doc_url, written_rows: $written_rows, columns: $columns}'
