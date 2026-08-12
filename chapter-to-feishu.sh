#!/usr/bin/env bash
# 单节生财课程内容 JSON → 飞书文档（全自动：解析 block + 下载图片 + 写飞书文档）
# Usage: chapter-to-feishu.sh <chapter.json>
#   chapter.json: getChapterContent API 返回的 data.chapter（含 title/id/content）
#
# 产物: 在 <chapter.json> 同级建 <id>/ 目录，内含 正文.md + img/，并生成一份飞书文档
# stdout 最后一行: write-custom-doc.sh 的结果 JSON（含 doc_url）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="${1:?usage: chapter-to-feishu.sh <chapter.json>}"

if [ ! -f "$JSON" ]; then
  echo "chapter.json not found: $JSON" >&2
  exit 1
fi

TITLE=$(jq -r '.title' "$JSON")
ID=$(jq -r '.id' "$JSON")
DIR="$(dirname "$JSON")"
WORKDIR="${DIR}/${ID}"
rm -rf "${WORKDIR}"  # 重跑清空旧图（避免 webp/png 混存）
mkdir -p "${WORKDIR}/img"

echo "[chapter-to-feishu] 章节: ${TITLE} (id=${ID})" >&2

# 1. 解析 block → 正文.md + 下载图片
python3 "${SCRIPT_DIR}/chapter_parse.py" "$JSON" "${WORKDIR}/正文.md" "${WORKDIR}/img" >&2

# 2. 生成飞书文档（复用通用脚本）
bash "${SCRIPT_DIR}/write-custom-doc.sh" \
  "生财·游戏站手册 - ${TITLE}" \
  "${WORKDIR}/正文.md" \
  "${WORKDIR}/img"
