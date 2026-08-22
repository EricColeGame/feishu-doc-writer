#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
[ -f "${SKILL_DIR}/.env" ] && { set -a; source "${SKILL_DIR}/.env"; set +a; }
source "${SKILL_DIR}/lib/feishu-api.sh"

INPUT_FILE=""
TITLE_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT_FILE="${2:-}"; shift 2 ;;
    --title) TITLE_OVERRIDE="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --input FILE [--title TITLE]" >&2; exit 2 ;;
  esac
done

[ -f "$INPUT_FILE" ] || { echo "input file is required" >&2; exit 2; }
: "${FEISHU_APP_ID:?FEISHU_APP_ID is required}"
: "${FEISHU_APP_SECRET:?FEISHU_APP_SECRET is required}"
: "${FEISHU_DOC_DOMAIN:?FEISHU_DOC_DOMAIN is required}"
jq -e '.headers|type=="array" and length>0' "$INPUT_FILE" >/dev/null
jq -e '.rows|type=="array"' "$INPUT_FILE" >/dev/null
jq -e '(.headers|length) as $n | all(.rows[]; type=="array" and length==$n)' "$INPUT_FILE" >/dev/null

TITLE="${TITLE_OVERRIDE:-$(jq -r '.title // "数据分析报告"' "$INPUT_FILE")}"
HEADERS="$(jq -c '.headers|map(tostring)' "$INPUT_FILE")"
ROWS="$(jq -c '.rows|map(map(tostring))' "$INPUT_FILE")"
COLS="$(jq 'length' <<<"$HEADERS")"
WIDTHS="$(jq -c --argjson cols "$COLS" 'if (.col_widths|type)=="array" and (.col_widths|length)==$cols then .col_widths else [range(0;$cols)|200] end' "$INPUT_FILE")"
TOTAL="$(jq 'length' <<<"$ROWS")"

# 飞书 Docx 原生表格实测 8 列稳定，10 列返回 1770001 invalid param；9 列不作为可用边界。
[ "$COLS" -le 8 ] || { echo "table supports at most 8 columns, got ${COLS}" >&2; exit 2; }

TOKEN="$(get_feishu_token)"
DOC_TOKEN="$(create_document "$TOKEN" "$TITLE")"
SUBTITLE="$(jq -r '.subtitle // empty' "$INPUT_FILE")"
if [ -n "$SUBTITLE" ]; then
  append_content "$TOKEN" "$DOC_TOKEN" "$SUBTITLE"
fi

create_table_with_data "$TOKEN" "$DOC_TOKEN" "$HEADERS" "$ROWS" "$WIDTHS" >/dev/null

jq -nc --arg doc_token "$DOC_TOKEN" --arg doc_url "https://${FEISHU_DOC_DOMAIN}/docx/${DOC_TOKEN}" \
  --argjson rows "$TOTAL" --argjson columns "$COLS" \
  '{status:"success",doc_token:$doc_token,doc_url:$doc_url,written_rows:$rows,columns:$columns}'
