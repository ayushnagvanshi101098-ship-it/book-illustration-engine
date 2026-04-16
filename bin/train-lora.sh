#!/usr/bin/env bash
# train-lora.sh — Train a FAL FLUX LoRA from character reference images.
#
# Usage:
#   train-lora.sh \
#     --character-id char-01 \
#     --trigger-word "riya_char" \
#     --images-dir <characters/char-01-riya/refs/> \
#     --output <characters/char-01-riya/>
#
# Uploads a zip of images to FAL CDN, submits training to
# fal-ai/flux-lora-fast-training, polls until complete, writes lora.json.
#
# Requires: $FAL_KEY, curl, jq, zip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/fal-helpers.sh"

FAL_ENDPOINT="fal-ai/flux-lora-fast-training"
TRAINING_STEPS=1000
TIMEOUT_SEC=900  # 15 min — FAL queue can take 5-10 min before training starts

print_help() {
  cat <<'HELP'
train-lora.sh — Train a FLUX LoRA on FAL from character reference images

Required:
  --character-id <id>       Character ID (e.g., char-01)
  --trigger-word <word>     Trigger word for the LoRA (e.g., riya_char)
  --images-dir <dir>        Directory containing reference images (JPEG/PNG)
  --output <dir>            Directory to write lora.json with results

Optional:
  --steps <N>               Training steps (default: 1000)
  --timeout <sec>           Max wait time in seconds (default: 600)
  --force                   Overwrite existing lora.json
  --help                    Show this help
HELP
}

CHAR_ID=""
TRIGGER_WORD=""
IMAGES_DIR=""
OUTPUT_DIR=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --character-id) CHAR_ID="$2"; shift 2 ;;
    --trigger-word) TRIGGER_WORD="$2"; shift 2 ;;
    --images-dir) IMAGES_DIR="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --steps) TRAINING_STEPS="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; print_help >&2; exit 1 ;;
  esac
done

[[ -n "$CHAR_ID" && -n "$TRIGGER_WORD" && -n "$IMAGES_DIR" && -n "$OUTPUT_DIR" ]] || {
  echo "error: --character-id, --trigger-word, --images-dir, and --output are all required" >&2
  print_help >&2
  exit 1
}
[[ -d "$IMAGES_DIR" ]] || { echo "error: images-dir $IMAGES_DIR not found" >&2; exit 1; }

fal_check_auth

LORA_JSON="$OUTPUT_DIR/lora.json"
if [[ -f "$LORA_JSON" ]] && (( FORCE == 0 )); then
  echo "error: $LORA_JSON already exists. Use --force to overwrite." >&2
  exit 1
fi

# Count images
IMG_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 \( -name "*.jpeg" -o -name "*.jpg" -o -name "*.png" \) | wc -l | tr -d ' ')
if (( IMG_COUNT < 4 )); then
  echo "error: need at least 4 images for LoRA training, found $IMG_COUNT in $IMAGES_DIR" >&2
  exit 1
fi
echo "→ found $IMG_COUNT reference images in $IMAGES_DIR" >&2

# Step 1: Upload images as zip
echo "→ uploading images to FAL CDN..." >&2
ZIP_URL=$(fal_upload_zip "$IMAGES_DIR") || { echo "error: zip upload failed" >&2; exit 1; }
echo "  ✓ uploaded: $ZIP_URL" >&2

# Step 2: Submit training job
echo "→ submitting LoRA training job (${TRAINING_STEPS} steps)..." >&2
PAYLOAD=$(jq -n \
  --arg url "$ZIP_URL" \
  --arg trigger "$TRIGGER_WORD" \
  --argjson steps "$TRAINING_STEPS" \
  '{
    images_data_url: $url,
    trigger_word: $trigger,
    steps: $steps,
    is_style: false,
    create_masks: true
  }')

REQUEST_ID=$(fal_queue_submit "$FAL_ENDPOINT" "$PAYLOAD") || {
  echo "error: training job submit failed" >&2
  exit 1
}
echo "  ✓ request_id: $REQUEST_ID" >&2

# Step 3: Poll until complete
echo "→ polling for completion (timeout: ${TIMEOUT_SEC}s)..." >&2
POLL_RESULT=$(fal_queue_poll "$FAL_ENDPOINT" "$REQUEST_ID" "$TIMEOUT_SEC" 15) || {
  echo "error: training failed or timed out" >&2
  mkdir -p "$OUTPUT_DIR"
  jq -n \
    --arg id "$CHAR_ID" \
    --arg trigger "$TRIGGER_WORD" \
    --arg request_id "$REQUEST_ID" \
    --arg error "$POLL_RESULT" \
    '{
      character_id: $id,
      trigger_word: $trigger,
      status: "failed",
      request_id: $request_id,
      error: $error
    }' > "$LORA_JSON"
  exit 1
}

# Step 4: Fetch result
echo "→ fetching training result..." >&2
RESULT=$(fal_queue_result "$FAL_ENDPOINT" "$REQUEST_ID") || {
  echo "error: failed to fetch result" >&2
  exit 1
}

WEIGHTS_URL=$(echo "$RESULT" | jq -r '.diffusers_lora_file.url')
CONFIG_URL=$(echo "$RESULT" | jq -r '.config_file.url // empty')

if [[ -z "$WEIGHTS_URL" || "$WEIGHTS_URL" == "null" ]]; then
  echo "error: no weights URL in training result" >&2
  echo "$RESULT" | jq . >&2
  exit 1
fi

# Step 5: Write lora.json
mkdir -p "$OUTPUT_DIR"
jq -n \
  --arg id "$CHAR_ID" \
  --arg trigger "$TRIGGER_WORD" \
  --arg weights_url "$WEIGHTS_URL" \
  --arg config_url "${CONFIG_URL:-}" \
  --arg request_id "$REQUEST_ID" \
  --argjson steps "$TRAINING_STEPS" \
  --argjson img_count "$IMG_COUNT" \
  --arg trained_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    character_id: $id,
    trigger_word: $trigger,
    status: "trained",
    weights_url: $weights_url,
    config_url: $config_url,
    request_id: $request_id,
    training_steps: $steps,
    image_count: $img_count,
    trained_at: $trained_at
  }' > "$LORA_JSON"

echo "✓ LoRA trained for $CHAR_ID" >&2
echo "  weights: $WEIGHTS_URL" >&2
echo "  config:  $LORA_JSON" >&2

cat "$LORA_JSON"
