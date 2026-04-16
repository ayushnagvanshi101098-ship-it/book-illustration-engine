#!/usr/bin/env bash
# gen-scene.sh — Generate a single book illustration using Nano Banana Pro
# with edit-mode style transfer (preserves the style reference pixel-tight).
#
# Usage:
#   gen-scene.sh --brief <brief.md|brief.txt> \
#                --style-ref <style-ref.png> \
#                --output <output.jpeg> \
#                [--character-ref <char.png>] ...
#
# The brief file's body (after any YAML frontmatter) becomes the scene
# description. The style-ref is passed as the first -r argument to
# nano-banana; character refs are appended as additional -r arguments.
#
# Prompt template uses the "Transform this image: replace X with Y,
# preserve exact style" framing, which is the proven strongest style
# lock for this engine (see project_book_illustration_workflow.md memory).
#
# Model: Nano Banana Pro (--model pro), 2K size, 1:1 aspect.
#
# Requires: nano-banana CLI installed and authenticated.

set -euo pipefail

print_help() {
  cat <<'HELP'
gen-scene.sh — Generate one book illustration via Nano Banana Pro edit-mode

Required:
  --brief <file>        Path to the brief markdown or text file
  --style-ref <file>    Path to the style reference image (PNG/JPEG)
  --output <file>       Output path (must end in .jpeg)

Optional:
  --character-ref <file>  Additional character reference (repeatable)
  --help                  Show this help

Example:
  gen-scene.sh \
    --brief books/my-book/briefs/scene-04-pied-piper.md \
    --style-ref books/my-book/style-ref.png \
    --output books/my-book/gens/scene-04-v1.jpeg
HELP
}

BRIEF=""
STYLE_REF=""
OUTPUT=""
CHAR_REFS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) BRIEF="$2"; shift 2 ;;
    --style-ref) STYLE_REF="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --character-ref) CHAR_REFS+=("$2"); shift 2 ;;
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
command -v nano-banana >/dev/null || { echo "error: nano-banana not on PATH" >&2; exit 1; }

# Strip YAML frontmatter if present (between leading --- lines).
BRIEF_BODY=$(awk '
  BEGIN { in_front=0; past_front=0 }
  /^---$/ {
    if (NR == 1) { in_front=1; next }
    if (in_front) { in_front=0; past_front=1; next }
  }
  !in_front { print }
' "$BRIEF" | sed '/^$/d' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')

[[ -n "$BRIEF_BODY" ]] || { echo "error: brief body is empty after frontmatter strip" >&2; exit 1; }

# Build the edit-mode prompt. Generic wording so it inherits palette/texture
# from whatever style-ref the book brings — no hard-coded color assumptions.
PROMPT="Transform this image: replace the current subjects and setting with the following scene — ${BRIEF_BODY} CRITICAL: preserve the EXACT art style of the reference image — same brush strokes, same linework texture, same shading technique, same color palette, same hand-painted children's book illustration quality. Only change the subjects and setting described in the brief. Keep the art style pixel-perfect identical to the reference. Pure solid white sky at the top of the frame, no clouds, no texture, no gradient."

# Assemble -r arguments: style-ref first, then any character refs.
REF_ARGS=(-r "$STYLE_REF")
if [[ ${#CHAR_REFS[@]} -gt 0 ]]; then
  for c in "${CHAR_REFS[@]}"; do
    [[ -f "$c" ]] || { echo "error: character-ref $c not found" >&2; exit 1; }
    REF_ARGS+=(-r "$c")
  done
fi

# nano-banana writes to <dir>/<name>.jpeg — we split OUTPUT into dir + name.
OUT_DIR=$(dirname "$OUTPUT")
OUT_BASE=$(basename "$OUTPUT" .jpeg)
mkdir -p "$OUT_DIR"

# Refuse to overwrite existing output unless --force (not yet exposed).
if [[ -e "$OUTPUT" ]]; then
  echo "error: $OUTPUT already exists — move or delete it first" >&2
  exit 1
fi

echo "→ generating: $OUTPUT" >&2
nano-banana "$PROMPT" \
  "${REF_ARGS[@]}" \
  --model pro \
  -s 2K -a 1:1 \
  -o "$OUT_BASE" \
  -d "$OUT_DIR"

# Verify output actually landed.
[[ -f "$OUTPUT" ]] || { echo "error: generation produced no output file" >&2; exit 1; }
echo "✓ $OUTPUT" >&2
