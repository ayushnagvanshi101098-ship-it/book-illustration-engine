#!/usr/bin/env bash
# gen-character-sheet.sh — DEPRECATED in v2.
#
# Character consistency is now handled by:
#   1. gen-char-refs.sh — generates reference images via NB Pro
#   2. train-lora.sh — trains a FAL FLUX LoRA from those refs
#   3. gen-scene-fal.sh — generates scenes with the trained LoRA
#
# The SKILL.md orchestrator calls these directly. This script exists
# only for backwards compatibility messaging.

set -euo pipefail

cat >&2 <<'EOF'
gen-character-sheet.sh: DEPRECATED in v2

Character consistency is now handled by the v2 pipeline:
  1. bin/gen-char-refs.sh    — generate reference images via NB Pro
  2. bin/train-lora.sh       — train a FAL FLUX LoRA from refs
  3. bin/gen-scene-fal.sh    — generate scenes with trained LoRA

The SKILL.md orchestrator manages this workflow automatically.
Run the book-illustration skill to use the full pipeline.

See: docs/architecture.md in the engine repository for the v2 design spec.
EOF
exit 2
