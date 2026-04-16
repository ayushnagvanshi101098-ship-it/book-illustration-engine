#!/usr/bin/env bash
# upscale.sh — Upscale an image 2x via FAL ESRGAN.
#
# Usage:
#   upscale.sh --input <image.jpeg> --output <upscaled.png>
#
# Uploads the input to FAL CDN, calls fal-ai/esrgan with 2x scale,
# downloads the result. Output is always PNG (lossless).
#
# Requires: $FAL_KEY, curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/fal-helpers.sh"

FAL_ENDPOINT="fal-ai/esrgan"

print_help() {
  cat <<'HELP'
upscale.sh — Upscale an image 2x via FAL ESRGAN

Required:
  --input <file>      Input image (JPEG or PNG)
  --output <file>     Output path (will be PNG)

Optional:
  --scale <N>         Scale factor (default: 2, range: 1-4)
  --force             Overwrite existing output
  --help              Show this help
HELP
}

INPUT=""
OUTPUT=""
SCALE=2
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
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

echo "→ upscaling ${SCALE}x via FAL ESRGAN..." >&2
PAYLOAD=$(jq -n \
  --arg url "$IMAGE_URL" \
  --argjson scale "$SCALE" \
  '{
    image_url: $url,
    scale: $scale,
    model: "RealESRGAN_x4plus",
    face: false,
    output_format: "png"
  }')

RESULT=$(fal_sync_call "$FAL_ENDPOINT" "$PAYLOAD") || {
  echo "error: ESRGAN call failed" >&2
  exit 1
}

RESULT_URL=$(echo "$RESULT" | jq -r '.image.url')
if [[ -z "$RESULT_URL" || "$RESULT_URL" == "null" ]]; then
  echo "error: no image URL in ESRGAN response" >&2
  echo "$RESULT" | jq . >&2
  exit 1
fi

echo "→ downloading upscaled image..." >&2
fal_download "$RESULT_URL" "$OUTPUT" || { echo "error: download failed" >&2; exit 1; }

RESULT_W=$(echo "$RESULT" | jq -r '.image.width // "unknown"')
RESULT_H=$(echo "$RESULT" | jq -r '.image.height // "unknown"')
echo "✓ $OUTPUT (${RESULT_W}x${RESULT_H})" >&2
