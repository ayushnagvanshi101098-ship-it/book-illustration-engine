#!/usr/bin/env bash
# gen-char-refs.sh — Generate reference images for one character via Nano Banana Pro.
# These images become training data for FAL FLUX LoRA.
#
# Usage:
#   gen-char-refs.sh \
#     --character-desc "8-year-old girl with two braids, blue school uniform" \
#     --character-id char-01 \
#     --style-ref <style-ref.png> \
#     --output-dir <characters/char-01-riya/refs/>
#
# Generates 6 images: front, side, face close-up, action, back, three-quarter.
# Model: Nano Banana Pro, 2K, 1:1 aspect.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

print_help() {
  cat <<'HELP'
gen-char-refs.sh — Generate character reference images for LoRA training

Required:
  --character-desc <text>   Character description (age, features, clothing)
  --character-id <id>       Character ID (e.g., char-01)
  --style-ref <file>        Style reference image
  --output-dir <dir>        Directory to write reference images

Optional:
  --count <N>               Number of reference images (default: 6, max: 8)
  --force                   Overwrite existing images
  --help                    Show this help
HELP
}

CHAR_DESC=""
CHAR_ID=""
STYLE_REF=""
OUT_DIR=""
COUNT=6
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --character-desc) CHAR_DESC="$2"; shift 2 ;;
    --character-id) CHAR_ID="$2"; shift 2 ;;
    --style-ref) STYLE_REF="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; print_help >&2; exit 1 ;;
  esac
done

[[ -n "$CHAR_DESC" && -n "$CHAR_ID" && -n "$STYLE_REF" && -n "$OUT_DIR" ]] || {
  echo "error: --character-desc, --character-id, --style-ref, and --output-dir are all required" >&2
  print_help >&2
  exit 1
}
[[ -f "$STYLE_REF" ]] || { echo "error: style-ref $STYLE_REF not found" >&2; exit 1; }
command -v nano-banana >/dev/null || { echo "error: nano-banana not on PATH" >&2; exit 1; }
(( COUNT >= 4 && COUNT <= 8 )) || { echo "error: --count must be 4-8" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Check for existing images unless --force
if (( FORCE == 0 )); then
  existing=$(find "$OUT_DIR" -name "*.jpeg" 2>/dev/null | wc -l | tr -d ' ')
  if (( existing > 0 )); then
    echo "error: $OUT_DIR already has $existing images. Use --force to overwrite." >&2
    exit 1
  fi
fi

# Pose definitions. Each: [filename_stem, pose_description]
POSES=(
  "front:standing facing the viewer, full body, arms at sides"
  "side:standing in side profile, full body, facing left"
  "face:close-up portrait of face and shoulders, looking at viewer"
  "action:running or jumping, full body, dynamic pose"
  "back:standing with back to viewer, full body, looking over shoulder"
  "threequarter:standing at three-quarter angle, full body, slight smile"
  "sitting:sitting cross-legged on the ground, full body"
  "waving:standing and waving with one hand raised, full body"
)

GENERATED=0
FAILED=0

for i in $(seq 0 $((COUNT - 1))); do
  pose_entry="${POSES[$i]}"
  stem="${pose_entry%%:*}"
  pose_desc="${pose_entry#*:}"
  output="$OUT_DIR/${stem}.jpeg"

  if [[ -e "$output" ]] && (( FORCE == 0 )); then
    echo "  skip: $output exists" >&2
    continue
  fi

  prompt="Transform this image: replace the current subject with ${CHAR_DESC}, ${pose_desc}. Single character only, plain solid white background, no other elements, no scenery. CRITICAL: preserve the EXACT art style of the reference image — same brush strokes, same linework texture, same shading technique, same color palette. Keep the art style pixel-perfect identical to the reference."

  echo "→ generating ref ($((i+1))/$COUNT): $stem" >&2
  if nano-banana "$prompt" \
    -r "$STYLE_REF" \
    --model pro \
    -s 2K -a 1:1 \
    -o "$stem" \
    -d "$OUT_DIR"; then
    if [[ -f "$output" ]]; then
      echo "  ✓ $stem" >&2
      GENERATED=$((GENERATED + 1))
    else
      echo "  ✗ $stem: no output file" >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  ✗ $stem: nano-banana failed" >&2
    FAILED=$((FAILED + 1))
  fi
done

echo "" >&2
echo "Character refs for $CHAR_ID: $GENERATED generated, $FAILED failed" >&2

if (( GENERATED < 4 )); then
  echo "error: need at least 4 refs for LoRA training, only got $GENERATED" >&2
  exit 1
fi

# Output JSON summary to stdout for the orchestrator
cat <<EOF
{
  "character_id": "$CHAR_ID",
  "output_dir": "$OUT_DIR",
  "generated": $GENERATED,
  "failed": $FAILED,
  "images": [$(cd "$OUT_DIR" && ls -1 *.jpeg 2>/dev/null | while read -r f; do echo "\"$f\""; done | paste -sd, -)]
}
EOF
