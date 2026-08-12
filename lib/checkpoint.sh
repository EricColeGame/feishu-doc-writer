#!/usr/bin/env bash
# Checkpoint 管理函数库

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINT_DIR="${FEISHU_CHECKPOINT_DIR:-${LIB_DIR}/../output/checkpoints}"

init_checkpoint() {
  local run_id="$1"
  local total_keywords="$2"
  local total_images="$3"
  local checkpoint_file="${CHECKPOINT_DIR}/${run_id}.json"

  mkdir -p "${CHECKPOINT_DIR}"

  jq -n \
    --arg run_id "$run_id" \
    --argjson total_kw "$total_keywords" \
    --argjson total_img "$total_images" \
    '{
      run_id: $run_id,
      doc_token: "",
      doc_url: "",
      status: "writing",
      phase: {
        current: "writing",
        writing: {
          total_keywords: $total_kw,
          written_keywords: 0,
          failed_keywords: [],
          last_success_batch: 0,
          total_batches: 0
        },
        image_inserting: {
          total_images: $total_img,
          replaced_images: 0,
          failed_images: [],
          remaining_placeholders: $total_img
        }
      },
      written_keyword_list: [],
      replaced_placeholder_list: [],
      updated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }' > "$checkpoint_file"

  echo "$checkpoint_file"
}

load_checkpoint() {
  local checkpoint_file="$1"

  if [ ! -f "$checkpoint_file" ]; then
    echo "{}"
    return 1
  fi

  cat "$checkpoint_file"
}

update_checkpoint() {
  local checkpoint_file="$1"
  local updates="$2"

  local current
  current=$(cat "$checkpoint_file")

  echo "$current" | jq --argjson updates "$updates" \
    '. * $updates | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    > "$checkpoint_file"
}

mark_keyword_written() {
  local checkpoint_file="$1"
  local keyword="$2"
  local batch_index="$3"

  local current written_count
  current=$(cat "$checkpoint_file")
  written_count=$(echo "$current" | jq -r '.phase.writing.written_keywords')

  echo "$current" | jq \
    --arg kw "$keyword" \
    --argjson batch "$batch_index" \
    --argjson new_count "$((written_count + 1))" \
    '.phase.writing.written_keywords = $new_count |
     .phase.writing.last_success_batch = $batch |
     .written_keyword_list += [$kw] |
     .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    > "$checkpoint_file"
}

mark_image_replaced() {
  local checkpoint_file="$1"
  local placeholder="$2"

  local current replaced_count remaining_count
  current=$(cat "$checkpoint_file")
  replaced_count=$(echo "$current" | jq -r '.phase.image_inserting.replaced_images')
  remaining_count=$(echo "$current" | jq -r '.phase.image_inserting.remaining_placeholders')

  echo "$current" | jq \
    --arg ph "$placeholder" \
    --argjson new_replaced "$((replaced_count + 1))" \
    --argjson new_remaining "$((remaining_count - 1))" \
    '.phase.image_inserting.replaced_images = $new_replaced |
     .phase.image_inserting.remaining_placeholders = $new_remaining |
     .replaced_placeholder_list += [$ph] |
     .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    > "$checkpoint_file"
}

is_keyword_written() {
  local checkpoint_file="$1"
  local keyword="$2"

  if [ ! -f "$checkpoint_file" ]; then
    return 1
  fi

  jq -e --arg kw "$keyword" '.written_keyword_list | index($kw) != null' "$checkpoint_file" >/dev/null 2>&1
}

is_placeholder_replaced() {
  local checkpoint_file="$1"
  local placeholder="$2"

  if [ ! -f "$checkpoint_file" ]; then
    return 1
  fi

  jq -e --arg ph "$placeholder" '.replaced_placeholder_list | index($ph) != null' "$checkpoint_file" >/dev/null 2>&1
}

get_checkpoint_doc_token() {
  local checkpoint_file="$1"

  if [ ! -f "$checkpoint_file" ]; then
    echo ""
    return 1
  fi

  jq -r '.doc_token // ""' "$checkpoint_file"
}

update_doc_info() {
  local checkpoint_file="$1"
  local doc_token="$2"
  local doc_url="$3"

  local current
  current=$(cat "$checkpoint_file")

  echo "$current" | jq \
    --arg token "$doc_token" \
    --arg url "$doc_url" \
    '.doc_token = $token |
     .doc_url = $url |
     .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    > "$checkpoint_file"
}

update_phase() {
  local checkpoint_file="$1"
  local phase="$2"

  local current
  current=$(cat "$checkpoint_file")

  echo "$current" | jq \
    --arg p "$phase" \
    '.status = $p |
     .phase.current = $p |
     .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    > "$checkpoint_file"
}
