# Sample: The Fox and the Grapes

A 3-scene Aesop fable, public domain. Use this to confirm the engine
runs end-to-end before pointing it at your own book.

## Standalone bash

```bash
# from the repo root, with .env populated
bin/parse-doc.sh examples/fox-and-grapes/manuscript.docx -o /tmp/fox-parsed.txt
bin/gen-scene.sh \
  --brief "A red fox stands on his hind legs in a sunlit orchard..." \
  --style-ref examples/fox-and-grapes/style-ref.png \
  --output /tmp/fox-scene-1.jpeg
bin/upscale.sh --input /tmp/fox-scene-1.jpeg --output /tmp/fox-scene-1-4k.png
bin/bg-remove-fal.sh --input /tmp/fox-scene-1-4k.png --output /tmp/fox-scene-1-final.png
```

## Claude Code

In a Claude Code session with this plugin installed:

> Illustrate examples/fox-and-grapes/manuscript.docx, style ref examples/fox-and-grapes/style-ref.png

The skill will plan, estimate cost, and wait for your "go" before
spending anything.
