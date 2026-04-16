#!/usr/bin/env bash
# gen-scene-fal.sh — Generate a single book illustration using FAL FLUX LoRA.
#
# Uses the img2img endpoint with style-ref as the base image and character
# LoRA(s) for consistency. This is the FAL equivalent of gen-scene.sh's
# NB Pro edit-mode approach.
#
# Usage:
#   gen-scene-fal.sh \
#     --brief <brief.md> \
#     --style-ref <style-ref.png> \
#     --output <output.jpeg> \
#     [--lora <char-id>:<trigger-word>:<weights-url>] ...
#
# Requires: $FAL_KEY, curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/fal-helpers.sh"

FAL_ENDPOINT="fal-ai/flux-lora/image-to-image"

print_help() {
  cat <<'HELP'
gen-scene-fal.sh — Generate one book illustration via FAL FLUX LoRA

Required:
  --brief <file>        Path to the brief markdown or text file
  --style-ref <file>    Path to the style reference image (used as img2img base)
  --output <file>       Output path (must end in .jpeg or .png)

Optional:
  --lora <id:trigger:url>  LoRA spec — character-id:trigger-word:weights-url (repeatable)
  --lora-scale <float>     LoRA influence scale (default: 1.0)
  --strength <float>       img2img strength 0-1 (default: 0.75, lower = more style-ref)
  --steps <N>              Inference steps (default: 28)
  --guidance <float>       CFG guidance scale (default: 3.5)
  --seed <N>               Seed for reproducibility
  --force                  Overwrite existing output
  --help                   Show this help
HELP
}

BRIEF=""
STYLE_REF=""
OUTPUT=""
LORAS=()
LORA_SCALE=1.0
STRENGTH=0.75
STEPS=28
GUIDANCE=3.5
SEED=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) BRIEF="$2"; shift 2 ;;
    --style-ref) STYLE_REF="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --lora) LORAS+=("$2"); shift 2 ;;
    --lora-scale) LORA_SCALE="$2"; shift 2 ;;
    --strength) STRENGTH="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --guidance) GUIDANCE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; print_help >&2; exit 1 ;;
  esac
done

[[ -n "$BRIEF" && -n "$STYLE_REF" && -n "$OUTPUT" ]] || {
  echo "error: --brief, --style-ref, and --output are all required" >&2
  print_help >&2
  exit 1
}
[[ -f "$BRIEF" ]]     || { echo "error: brief file $BRIEF not found" >&2; exit 1; }
[[ -f "$STYLE_REF" ]] || { echo "error: style-ref $STYLE_REF not found" >&2; exit 1; }

fal_check_auth

OUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUT_DIR"

if [[ -e "$OUTPUT" ]] && (( FORCE == 0 )); then
  echo "error: $OUTPUT already exists — move or delete it first, or use --force" >&2
  exit 1
fi

# Strip YAML frontmatter from brief (same logic as gen-scene.sh)
BRIEF_BODY=$(awk '
  BEGIN { in_front=0; past_front=0 }
  /^---$/ {
    if (NR == 1) { in_front=1; next }
    if (in_front) { in_front=0; past_front=1; next }
  }
  !in_front { print }
' "$BRIEF" | sed '/^$/d' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')

[[ -n "$BRIEF_BODY" ]] || { echo "error: brief body is empty after frontmatter strip" >&2; exit 1; }

# Build prompt — inject trigger words where character names appear
PROMPT="$BRIEF_BODY Children's book illustration, matching the art style of the reference image exactly — same brush strokes, same linework, same color palette, same shading technique."

# Inject trigger words into prompt
for lora_spec in "${LORAS[@]+"${LORAS[@]}"}"; do
  IFS=':' read -r char_id trigger_word weights_url <<< "$lora_spec"
  PROMPT="${trigger_word}, ${PROMPT}"
done

# Upload style-ref to FAL CDN
echo "→ uploading style-ref to FAL CDN..." >&2
STYLE_URL=$(fal_upload_file "$STYLE_REF") || { echo "error: style-ref upload failed" >&2; exit 1; }

# Build LoRA array for payload
LORA_JSON="[]"
for lora_spec in "${LORAS[@]+"${LORAS[@]}"}"; do
  IFS=':' read -r char_id trigger_word weights_url <<< "$lora_spec"
  LORA_JSON=$(echo "$LORA_JSON" | jq \
    --arg path "$weights_url" \
    --argjson scale "$LORA_SCALE" \
    '. + [{"path": $path, "scale": $scale}]')
done

# Build payload
PAYLOAD=$(jq -n \
  --arg prompt "$PROMPT" \
  --arg image_url "$STYLE_URL" \
  --argjson loras "$LORA_JSON" \
  --argjson strength "$STRENGTH" \
  --argjson steps "$STEPS" \
  --argjson guidance "$GUIDANCE" \
  '{
    prompt: $prompt,
    image_url: $image_url,
    loras: $loras,
    strength: $strength,
    num_inference_steps: $steps,
    guidance_scale: $guidance,
    image_size: {"width": 1024, "height": 1024},
    num_images: 1,
    output_format: "jpeg",
    enable_safety_checker: false
  }')

# Add seed if specified
if [[ -n "$SEED" ]]; then
  PAYLOAD=$(echo "$PAYLOAD" | jq --argjson seed "$SEED" '. + {seed: $seed}')
fi

echo "→ generating scene via FAL FLUX LoRA..." >&2

RESULT=$(fal_sync_call "$FAL_ENDPOINT" "$PAYLOAD") || {
  echo "error: FAL inference failed" >&2
  exit 1
}

IMAGE_URL=$(echo "$RESULT" | jq -r '.images[0].url')
if [[ -z "$IMAGE_URL" || "$IMAGE_URL" == "null" ]]; then
  echo "error: no image URL in FAL response" >&2
  echo "$RESULT" | jq . >&2
  exit 1
fi

echo "→ downloading result..." >&2
fal_download "$IMAGE_URL" "$OUTPUT" || { echo "error: download failed" >&2; exit 1; }

[[ -f "$OUTPUT" ]] || { echo "error: generation produced no output file" >&2; exit 1; }

echo "✓ $OUTPUT" >&2

SEED_ACTUAL=$(echo "$RESULT" | jq -r '.seed // "null"')
cat <<EOF
{
  "output": "$OUTPUT",
  "route": "fal",
  "model": "flux-lora",
  "loras_used": $(echo "$LORA_JSON" | jq '[.[].path]'),
  "seed": $SEED_ACTUAL,
  "strength": $STRENGTH,
  "steps": $STEPS
}
EOF
