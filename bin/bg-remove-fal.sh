#!/usr/bin/env bash
# bg-remove-fal.sh — Remove background via FAL birefnet v2.
#
# Usage:
#   bg-remove-fal.sh --input <image.png> --output <transparent.png>
#
# Better than bgproof.sh for: hair/fur edges, semi-transparent watercolor
# bleeds, colored sky backgrounds. Costs ~$0.01 per image.
#
# Requires: $FAL_KEY, curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/fal-helpers.sh"

FAL_ENDPOINT="fal-ai/birefnet/v2"

print_help() {
  cat <<'HELP'
bg-remove-fal.sh — Remove background via FAL birefnet v2

Required:
  --input <file>      Input image (JPEG or PNG)
  --output <file>     Output path (will be PNG with alpha)

Optional:
  --model <name>      BiRefNet model (default: "General Use (Light)")
  --resolution <res>  Operating resolution (default: "1024x1024")
                      Options: "1024x1024", "2048x2048", "2304x2304"
  --force             Overwrite existing output
  --help              Show this help
HELP
}

INPUT=""
OUTPUT=""
MODEL="General Use (Light)"
RESOLUTION="1024x1024"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --resolution) RESOLUTION="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; print_help >&2; exit 1 ;;
  esac
done

[[ -n "$INPUT" && -n "$OUTPUT" ]] || {
  echo "error: --input and --output are required" >&2
  print_help >&2
  exit 1
}
[[ -f "$INPUT" ]] || { echo "error: input $INPUT not found" >&2; exit 1; }

fal_check_auth

OUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUT_DIR"

if [[ -e "$OUTPUT" ]] && (( FORCE == 0 )); then
  echo "error: $OUTPUT already exists. Use --force to overwrite." >&2
  exit 1
fi

echo "→ uploading $INPUT to FAL CDN..." >&2
IMAGE_URL=$(fal_upload_file "$INPUT") || { echo "error: upload failed" >&2; exit 1; }

echo "→ removing background via FAL birefnet..." >&2
PAYLOAD=$(jq -n \
  --arg url "$IMAGE_URL" \
  --arg model "$MODEL" \
  --arg res "$RESOLUTION" \
  '{
    image_url: $url,
    model: $model,
    operating_resolution: $res,
    output_format: "png",
    refine_foreground: true
  }')

RESULT=$(fal_sync_call "$FAL_ENDPOINT" "$PAYLOAD") || {
  echo "error: birefnet call failed" >&2
  exit 1
}

RESULT_URL=$(echo "$RESULT" | jq -r '.image.url')
if [[ -z "$RESULT_URL" || "$RESULT_URL" == "null" ]]; then
  echo "error: no image URL in birefnet response" >&2
  echo "$RESULT" | jq . >&2
  exit 1
fi

echo "→ downloading transparent image..." >&2
fal_download "$RESULT_URL" "$OUTPUT" || { echo "error: download failed" >&2; exit 1; }

echo "✓ $OUTPUT" >&2
