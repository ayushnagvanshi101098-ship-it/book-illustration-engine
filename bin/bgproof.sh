#!/usr/bin/env bash
# bgproof.sh — Strip a light/cream/white background from a book illustration
# and produce a dark-bg proof image for visual verification.
#
# Matches the book illustration workflow (reverse-engineered from the
# clapping-child / pied-piper / train-window series on 2026-04-07).
#
# Usage:
#   bgproof.sh <input.jpg|png> [proof-bg-color] [fuzz-pct]
#
# Defaults:
#   proof-bg-color = #1a1a2e  (dark navy)
#   fuzz-pct       = 15       (how fuzzy the bg color match is, 0-100)
#
# Writes (next to input):
#   <stem>-transparent.png   real sRGBA alpha, bg removed
#   <stem>-proof.png         transparent composited on dark navy, for QA
#
# Requires: ImageMagick 7 (`magick` CLI).

set -euo pipefail

FORCE=0
if [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]]; then
  FORCE=1
  shift
fi

IN="${1:?usage: bgproof.sh [-f] <input.jpg|png> [proof-bg-color] [fuzz-pct]}"
BG="${2:-#1a1a2e}"
FUZZ="${3:-15}"

[[ -f "$IN" ]] || { echo "error: $IN not found" >&2; exit 1; }
command -v magick >/dev/null || { echo "error: ImageMagick 'magick' not on PATH" >&2; exit 1; }

STEM="${IN%.*}"
TRANS="${STEM}-transparent.png"
PROOF="${STEM}-proof.png"

# Never clobber unless -f. Lesson learned on 2026-04-09 when an overwrite
# destroyed hand-tuned originals.
if (( FORCE == 0 )); then
  for f in "$TRANS" "$PROOF"; do
    if [[ -e "$f" ]]; then
      echo "error: $f already exists. Use -f to overwrite, or move it aside." >&2
      exit 1
    fi
  done
fi

# 1) Alpha extract via corner floodfill.
#    Adds a 1px white border so the floodfill definitely starts in bg,
#    then shaves it off. Only touches background regions *connected* to
#    the edge — interior whites (eyes, highlights) stay opaque.
magick "$IN" \
  -alpha set \
  -bordercolor white -border 1 \
  -fuzz "${FUZZ}%" -fill none -floodfill +0+0 white \
  -shave 1x1 \
  "$TRANS"

# 2) Composite on dark bg for visual QA (fringing, missed bg, alpha leaks).
W=$(magick identify -format '%w' "$TRANS")
H=$(magick identify -format '%h' "$TRANS")
magick -size "${W}x${H}" "xc:${BG}" "$TRANS" -composite "$PROOF"

echo "  transparent: $TRANS"
echo "  proof:       $PROOF"
