#!/usr/bin/env bash
# parse-doc.sh — Convert a .docx or .pdf manuscript to numbered plain text.
#
# Usage:
#   parse-doc.sh <input.docx|input.pdf>              # prints to stdout
#   parse-doc.sh <input.docx|input.pdf> -o <out.txt> # writes to file
#
# Output format: each line prefixed with "NNNN: " (zero-padded to 4 digits),
# followed by the line content. This lets Claude grep for markers and cite
# exact source line numbers in the manifest.
#
# Supported formats:
#   .docx  → extracted via textutil (macOS built-in)
#   .pdf   → extracted via pdftotext (from brew install poppler)
#
# Requires: textutil (macOS), pdftotext (for PDF input)

set -euo pipefail

print_help() {
  cat <<'HELP'
parse-doc.sh — Convert .docx/.pdf to numbered plain text

Usage:
  parse-doc.sh <input.docx|input.pdf>
  parse-doc.sh <input.docx|input.pdf> -o <out.txt>
  parse-doc.sh --help

Example:
  parse-doc.sh ~/Downloads/story.docx
  parse-doc.sh ~/Downloads/story.pdf -o /tmp/story.txt
HELP
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

IN="$1"
OUT=""

if [[ $# -gt 1 ]]; then
  if [[ "${2:-}" == "-o" ]]; then
    if [[ -z "${3:-}" ]]; then
      echo "error: -o requires an output filename" >&2
      exit 1
    fi
    OUT="$3"
    if [[ $# -gt 3 ]]; then
      echo "error: unexpected arguments after -o <file>: ${*:4}" >&2
      exit 1
    fi
  else
    echo "error: unexpected argument: $2" >&2
    exit 1
  fi
fi

[[ -f "$IN" ]] || { echo "error: $IN not found" >&2; exit 1; }

EXT="${IN##*.}"
if [[ "$EXT" == "$IN" ]]; then
  echo "error: file has no extension; expected .docx or .pdf" >&2
  exit 1
fi
EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')  # lowercase, bash 3.2+ compatible
TMP=$(mktemp -t parsedoc.XXXXXX)
trap 'rm -f "$TMP"' EXIT

case "$EXT" in
  docx)
    command -v textutil >/dev/null || { echo "error: textutil not found (macOS only)" >&2; exit 1; }
    textutil -convert txt -stdout "$IN" > "$TMP"
    ;;
  pdf)
    command -v pdftotext >/dev/null || { echo "error: pdftotext not found (brew install poppler)" >&2; exit 1; }
    pdftotext -layout "$IN" "$TMP"
    ;;
  *)
    echo "error: unsupported format .$EXT (only .docx and .pdf supported)" >&2
    exit 1
    ;;
esac

# Emit numbered lines: "NNNN: content"
if [[ -n "$OUT" ]]; then
  awk '{ printf "%04d: %s\n", NR, $0 }' "$TMP" > "$OUT"
  echo "wrote: $OUT" >&2
else
  awk '{ printf "%04d: %s\n", NR, $0 }' "$TMP"
fi
