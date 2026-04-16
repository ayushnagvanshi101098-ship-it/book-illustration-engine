# Changelog

## 1.0.0 — 2026-04-16

Initial public release.

- 10 bash scripts in `bin/` covering manuscript parse, character refs,
  LoRA training, scene generation (FAL + Nano Banana paths), upscale,
  and background removal.
- Claude Code skill (`skills/book-illustration/SKILL.md`) orchestrating
  the full pipeline with auto-detected character routing, quality
  judging, and resumable manifests.
- One runnable sample: `examples/fox-and-grapes/`.
- Architecture doc: `docs/architecture.md`.
