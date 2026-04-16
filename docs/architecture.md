# Book Illustration Engine v2 — FAL Integration + Autonomous Quality

**Date:** 2026-04-10

## Overview

v2 upgrades the book illustration engine from a style-locked single-path generator to an autonomous smart-routed pipeline with character consistency (via FAL FLUX LoRA), quality judgment (via Claude vision), and print-ready post-processing (via FAL upscaling + background removal).

The engine auto-detects whether a book is narrative (recurring characters) or anthology (unique characters per scene) and routes each scene independently to the best generation path.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Book types supported | Both narrative + anthology equally | Real-world books aren't cleanly one or the other |
| Budget default | $12 USD (quality over cost) | FAL FLUX+LoRA as primary for narrative, NB Pro for anthology |
| Quality judgment | Generate 1, auto-judge via Claude vision, retry if bad | Catches garbage without burning budget on variants |
| Routing | Auto-detect from manuscript via character graph | No flags to remember, engine decides per-scene |
| Cross-book characters | Per-book isolation, structured for future shared library | v3 problem, but data schema supports it |
| Architecture | Smart Router — single pipeline, per-scene routing | Handles hybrid books (poetry with mascot) naturally |

---

## 1. Pipeline (10 Steps)

```
Step 1:  Bootstrap (v1 + new manifest fields)
Step 2:  Parse manuscript (v1 unchanged)
Step 3:  Extract briefs (v1 + extract character names per brief)
Step 4:  Build character graph (NEW — Claude reasoning)
Step 5:  Train LoRAs for recurring characters (NEW — FAL API)
Step 6:  Gate 1 — Plan Review (enhanced with characters + routing)
Step 7:  Generate scenes (smart-routed: FAL or NB Pro per scene)
Step 8:  Auto-judge via Claude vision (NEW)
Step 9:  Post-process: upscale + bg-remove + proof (enhanced)
Step 10: Report (enhanced with quality scores + routing summary)
```

Gate 3 (budget overrun) fires mid-generation same as v1.

---

## 2. Character Graph

After briefs are extracted (Step 3), Claude reads ALL briefs together and builds a character graph (Step 4). This is Claude reasoning inside SKILL.md, not a bash script.

### Output schema

```json
{
  "characters": [
    {
      "id": "char-01",
      "name": "Riya",
      "description": "8-year-old girl with two braids, blue school uniform, curious expression",
      "appears_in": ["scene-01", "scene-03", "scene-05", "scene-07"],
      "is_recurring": true,
      "lora_status": "pending"
    },
    {
      "id": "char-02",
      "name": "the balloon seller",
      "description": "elderly man with white beard, torn vest, red cart",
      "appears_in": ["scene-04"],
      "is_recurring": false,
      "lora_status": "skip"
    }
  ],
  "scene_routing": {
    "scene-01": { "route": "fal", "reason": "recurring character: Riya" },
    "scene-04": { "route": "nano_banana", "reason": "no recurring characters" }
  }
}
```

### Rules

- A character is "recurring" if they appear in 2+ scenes.
- Only recurring characters get LoRA training. One-offs handled by prompt alone.
- If a scene has ANY recurring character, route to FAL FLUX+LoRA.
- If a scene has zero recurring characters, route to NB Pro edit-mode.
- Character detection is semantic, not name-matching. "The girl with braids" and "Riya" in different briefs = same character if Claude judges them identical.
- The graph is stored in `manifest.json` under `characters[]` and each scene's `route` field.

### Anthology behavior

Character graph comes back empty or all one-offs. Every scene routes to NB Pro. Zero LoRA training. Engine behaves like v1 + auto-judge + upscaling.

---

## 3. LoRA Training Pipeline

For each recurring character (Step 5):

### Step 5a: Generate character reference images

Generate 5-8 reference images using NB Pro, varying pose/angle/expression, consistent with book's style-ref:

- Full body front-facing
- Full body side profile
- Close-up face
- Action pose (running/sitting/reaching)
- Back view
- 1-3 additional variations as needed

Prompt pattern: `"[character description] in [pose]. Art style: children's book illustration matching the reference image. Plain white background, single character only, no other elements."`

Output: `characters/char-01-riya/refs/`

### Step 5b: Submit to FAL FLUX LoRA training

```bash
train-lora.sh \
  --character-id char-01 \
  --trigger-word "riya_char" \
  --images-dir characters/char-01-riya/refs/ \
  --output characters/char-01-riya/
```

- Calls FAL `fal-ai/flux-lora-fast-training`
- Passes 5-8 images as training data
- Sets trigger word (e.g., `riya_char`)
- Training takes ~2-5 minutes per character
- Polls status every 15s until complete
- On success: saves LoRA weights URL + config to `characters/char-01-riya/lora.json`

### Step 5c: Update manifest

```json
{
  "id": "char-01",
  "name": "Riya",
  "lora_status": "trained",
  "trigger_word": "riya_char",
  "lora_weights_url": "https://...",
  "lora_config": "characters/char-01-riya/lora.json",
  "ref_images": ["characters/char-01-riya/refs/front.jpeg", "..."],
  "training_cost_usd": 0.72
}
```

### Failure handling

- Training fails → retry once. Still fails → mark character `lora_failed`.
- Scenes with failed-LoRA characters fall back to NB Pro (character description in prompt, no consistency guarantee).
- Gate 1 (Step 6, which runs AFTER training) shows the failure: "Riya LoRA failed — scenes 1,3,5,7 will use NB Pro fallback, character may look different across scenes." User can cancel or proceed with degraded consistency.

### Cost

~$0.50-1.00 per character LoRA training (API fee).
~$0.90-1.20 per character reference images (6-8 × $0.15 NB Pro).
Total per character: ~$1.40-2.20.

---

## 4. Smart-Routed Generation

Step 7 routes each scene independently.

### FAL route (scenes with recurring LoRA characters)

```bash
gen-scene-fal.sh \
  --brief briefs/scene-01-riya-discovers-garden.md \
  --style-ref style-ref.png \
  --lora char-01:riya_char \
  --lora char-03:dog_buddy_char \
  --output gens/scene-01-v1.jpeg
```

- Calls FAL `fal-ai/flux-lora` inference endpoint
- Prompt built from brief body + trigger words injected where characters are mentioned
- Style-ref passed as image input for style guidance
- Multiple LoRAs composable per scene
- Output: 2048x2048 JPEG
- Cost: ~$0.04-0.08 per image

### NB Pro route (scenes with no recurring characters)

Exactly v1's `gen-scene.sh`. No changes.

### Prompt construction for FAL route

1. Take the brief body text
2. Replace character references with trigger words: "Riya runs through the garden" → "riya_char runs through the garden"
3. Append style instruction: "Children's book illustration style matching the reference. [style-ref loaded as image guidance]"
4. No negative prompts unless auto-judge feedback loop suggests one on retry

### Per-scene cost tracking

Same `costs.json` ledger, each line item includes:

```json
{
  "ts": "...",
  "scene": "scene-01",
  "version": 1,
  "type": "generation",
  "route": "fal",
  "model": "flux-lora",
  "loras_used": ["char-01"],
  "cost_usd": 0.06
}
```

Budget pre-check before each gen: `spent + estimated_next <= cap`. FAL scenes cheaper per-gen (~$0.06) but LoRA training is front-loaded.

---

## 5. Auto-Judge via Claude Vision

Step 8: After each scene generation, Claude vision evaluates the image before post-processing.

### Five criteria (pass/fail each)

| Check | What it means | Fail example |
|---|---|---|
| Subject match | Right characters/objects/setting present | Brief says "girl on swing", image shows boy on bench |
| Style fidelity | Matches style-ref's art style | Style-ref is watercolor, output looks 3D |
| Anatomy/coherence | No broken hands, extra limbs, melted faces | Six fingers, floating head |
| Artifact check | No text artifacts, watermarks, banding | Random text in sky |
| Character match | LoRA character matches trained refs | Riya has different hair color |

### Input to judge

Claude receives in one vision call:
1. The generated scene
2. The style-ref
3. The character ref (if LoRA character, from training refs)
4. The brief text

### Output

```json
{
  "pass": false,
  "failures": ["anatomy"],
  "details": "Child has 6 fingers on left hand",
  "retry_hint": "Add 'anatomically correct hands' emphasis to prompt"
}
```

### Retry logic

- **Pass** → proceed to post-processing
- **Fail, attempt 1** → regenerate with `retry_hint` appended to prompt. Same route.
- **Fail, attempt 2** → regenerate one more time.
- **Fail, attempt 3** → mark scene `quality_failed`, Claude picks least-bad from all 3, flag in report.

Max 2 retries (3 total attempts) per scene. Each retry costs against budget.

### What it does NOT judge

- Aesthetic taste ("is this beautiful?") — too subjective
- Composition quality — hard to automate reliably
- Color palette accuracy — handled by style-ref matching

The engine judges for correctness, not beauty.

---

## 6. Post-Processing Pipeline

Step 9: Three stages, every scene regardless of route.

### Stage 1: Upscale to print resolution

```bash
upscale.sh \
  --input gens/scene-01-v1.jpeg \
  --output gens/scene-01-v1-upscaled.png \
  --target-size 4096
```

- FAL Real-ESRGAN or similar
- 2048 → 4096px (2x). At 300 DPI = ~13.6 inches (A4/Letter)
- Output: PNG (lossless)
- Cost: ~$0.01-0.02 per image

### Stage 2: Background removal (route-dependent)

**FAL-generated scenes:**

```bash
bg-remove-fal.sh \
  --input gens/scene-01-v1-upscaled.png \
  --output gens/scene-01-v1-transparent.png
```

- FAL birefnet model
- Better at hair/fur edges, semi-transparent watercolor bleeds
- Cost: ~$0.01 per image

**NB Pro-generated scenes:**

```bash
bgproof.sh gens/scene-01-v1-upscaled.png
```

- Same v1 path (ImageMagick floodfill), free
- Auto-fallback to FAL birefnet if colored sky detected (NEW)

### Stage 3: Proof composite

```bash
magick gens/scene-01-v1-transparent.png \
  -background '#1a1a2e' -flatten \
  final/scene-01-proof.png
```

### Smart fallback chain

```
bgproof.sh (local, free)
  ↓ fails (colored sky)
bg-remove-fal.sh (FAL birefnet, $0.01)
  ↓ fails (API error)
Mark bgproof_failed, keep upscaled PNG, flag in report
```

### Final output per scene

```
final/
  scene-01-transparent.png    # 4096px, sRGBA, print-ready
  scene-01-proof.png           # navy composite for QA
```

Originals preserved in `gens/`.

---

## 7. Manifest Schema v2

### New book-level fields

```json
{
  "book": {
    "schema_version": 2,
    "budget_usd_cap": 12.00,
    "book_type_detected": "narrative",
    "detection_reason": "3 recurring characters across 8 scenes"
  }
}
```

### Characters array (new)

```json
{
  "characters": [
    {
      "id": "char-01",
      "name": "Riya",
      "description": "8-year-old girl with two braids, blue school uniform",
      "appears_in": ["scene-01", "scene-03", "scene-05", "scene-07"],
      "is_recurring": true,
      "lora_status": "trained",
      "trigger_word": "riya_char",
      "lora_weights_url": "https://...",
      "lora_config": "characters/char-01-riya/lora.json",
      "ref_images": ["characters/char-01-riya/refs/front.jpeg"],
      "training_cost_usd": 0.72
    }
  ]
}
```

### New per-scene fields

```json
{
  "id": "scene-01",
  "route": "fal",
  "route_reason": "recurring characters: Riya, Buddy",
  "characters_featured": ["char-01", "char-03"],
  "loras_used": ["char-01", "char-03"],
  "quality_judgments": [
    {
      "attempt": 1,
      "pass": false,
      "failures": ["anatomy"],
      "details": "Child has 6 fingers on left hand",
      "retry_hint": "Emphasize anatomically correct hands"
    },
    {
      "attempt": 2,
      "pass": true,
      "failures": [],
      "details": "All checks passed"
    }
  ],
  "final_attempt": 2,
  "upscaled": true,
  "upscale_size": 4096,
  "bg_removal_method": "fal_birefnet"
}
```

### Cost line item types

```json
{
  "line_items": [
    { "type": "lora_refs", "character": "char-01", "cost_usd": 0.90 },
    { "type": "lora_training", "character": "char-01", "cost_usd": 0.72 },
    { "type": "generation", "scene": "scene-01", "route": "fal", "cost_usd": 0.06 },
    { "type": "generation", "scene": "scene-01", "route": "fal", "cost_usd": 0.06, "note": "retry: anatomy fail" },
    { "type": "upscale", "scene": "scene-01", "cost_usd": 0.02 },
    { "type": "bg_removal", "scene": "scene-01", "method": "fal_birefnet", "cost_usd": 0.01 }
  ]
}
```

### Migration

v1 manifests (`schema_version: 1`) continue to work. Engine detects version and adds missing fields with defaults on resume. No breaking changes.

---

## 8. Enhanced Gate 1

After character graph + routing decisions, engine presents full plan:

```
Book: "Adventures of Riya and Buddy"
Type detected: NARRATIVE (3 recurring characters across 8/12 scenes)

CHARACTERS
  char-01  Riya (8yo girl, braids, blue uniform)     → scenes 1,3,5,7,9,11  → TRAIN LORA
  char-02  Buddy (golden retriever puppy)             → scenes 1,5,9,11      → TRAIN LORA
  char-03  Ms. Sharma (teacher, grey sari)            → scenes 2,7           → TRAIN LORA
  char-04  the balloon seller (old man, red cart)      → scene 4 only         → SKIP (one-off)

SCENES — GENERATION PLAN
  scene-01  Riya meets Buddy at school gate            FAL+LoRA  [char-01, char-02]
  scene-02  Ms. Sharma writes on blackboard            FAL+LoRA  [char-03]
  scene-04  Balloon seller at the mela                 NB Pro    [no recurring chars]
  scene-08  (icon_grid)                                SKIP: not supported
  ...

COST ESTIMATE
  LoRA training:     3 characters × ~$0.75        = $2.25
  LoRA refs:         3 characters × 6 × $0.15     = $2.70
  FAL generations:   8 scenes × $0.06             = $0.48
  NB Pro generations: 2 scenes × $0.16            = $0.32
  Upscaling:         10 scenes × $0.02            = $0.20
  BG removal (FAL):  8 scenes × $0.01            = $0.08
  Retries (budget):  ~3 retries estimated         = $0.18
  ────────────────────────────────────────────────
  Estimated total:                                = $6.21
  Budget cap:                                      $12.00

Proceed? Reply "go", or:
  - "skip char-NN"          → don't train LoRA, scenes fall back to NB Pro
  - "skip scene-NN"         → mark scene skipped
  - "reroute scene-NN fal"  → force FAL route
  - "reroute scene-NN nb"   → force NB Pro route
  - "raise cap to N"
  - "cancel"
```

New commands vs v1: `skip char-NN`, `reroute scene-NN fal/nb`.

---

## 9. New Scripts

| Script | Purpose | Calls | Cost per call |
|---|---|---|---|
| `gen-char-refs.sh` | Generate 5-8 ref images for one character via NB Pro | nano-banana CLI | ~$0.15 per ref |
| `train-lora.sh` | Submit refs to FAL LoRA training, poll until done | FAL API | ~$0.50-1.00 |
| `gen-scene-fal.sh` | Generate one scene via FAL FLUX+LoRA | FAL API | ~$0.04-0.08 |
| `upscale.sh` | Upscale image 2x via FAL | FAL API | ~$0.01-0.02 |
| `bg-remove-fal.sh` | Remove background via FAL birefnet | FAL API | ~$0.01 |

Character graph building and quality judgment happen as Claude reasoning inside SKILL.md — not scripts. Both require holistic understanding that bash can't provide.

### Script conventions (same as v1)

- Named flags (`--input`, `--output`, `--brief`, etc.)
- Exit 0 success, non-zero failure
- Stderr for errors, stdout for structured output
- Refuse to clobber unless `-f`
- Validate inputs before API calls
- FAL scripts read `$FAL_KEY` from environment (auto-sourced from `~/.fal/credentials`)

---

## 10. Error Handling

### LoRA training failures

| Situation | Response |
|---|---|
| FAL API unreachable | Retry once after 30s. Fail → `lora_failed`, scenes fall back to NB Pro |
| Training quality bad | Detected via auto-judge at generation. 2+ failures with same LoRA → flag as suspect |
| Training timeout (>10 min) | Kill poll, `lora_timeout`, same fallback |
| FAL_KEY invalid | Halt entire run with clear message |

### Routing edge cases

| Situation | Response |
|---|---|
| Ambiguous recurring character | Claude reads context, groups by description not just name |
| Same character different names | Semantic matching during graph building |
| LoRA character + complex background | Route FAL. LoRA handles character, prompt handles scene |
| All one-offs (anthology) | Zero LoRA training, full NB Pro path, v1 behavior + auto-judge + upscale |

### Auto-judge edge cases

| Situation | Response |
|---|---|
| Judge passes bad image | User catches in proof review. Manual rerun available |
| All 3 attempts fail | Keep least-bad, mark `quality_failed`, flag in report |
| Abstract style-ref | Loose style matching — checks art medium consistency, not pixels |

### Post-processing edge cases

| Situation | Response |
|---|---|
| Upscaler returns blurry | No auto-detection. User reviews proofs at print size |
| birefnet leaves edge artifacts | Visible in proof PNG on navy. User can rerun or manual PS |
| Full bleed illustration (no bg) | birefnet still isolates foreground. User reviews result |

### Budget + retries

Each retry costs against budget. Pre-check before every attempt: `spent + estimated_next <= cap`. Gate 3 fires if cap would be exceeded.

---

## 11. Cost Model

### Narrative book (12 scenes, 3 recurring characters)

```
LoRA reference images:  3 × 6 × $0.15     = $2.70
LoRA training:          3 × $0.75          = $2.25
FAL generations:        9 × $0.06          = $0.54
NB Pro generations:     3 × $0.15          = $0.45
Retries (~20%):         ~2 × $0.08         = $0.16
Upscaling:              12 × $0.02         = $0.24
BG removal (FAL):       9 × $0.01          = $0.09
BG removal (bgproof):   3 × $0.00          = $0.00
──────────────────────────────────────────────
Total:                                     ≈ $6.43
```

### Anthology book (8 scenes, 0 recurring characters)

```
NB Pro generations:     8 × $0.15          = $1.20
Retries (~20%):         ~2 × $0.15         = $0.30
Upscaling:              8 × $0.02          = $0.16
BG removal (bgproof):   8 × $0.00          = $0.00
BG removal fallback:    ~2 × $0.01         = $0.02
──────────────────────────────────────────────
Total:                                     ≈ $1.68
```

### Hybrid book (10 scenes, 1 mascot character)

```
LoRA refs + training:   1 × ($0.90 + $0.75) = $1.65
FAL generations:        4 × $0.06           = $0.24
NB Pro generations:     6 × $0.15           = $0.90
Retries:                ~2 × $0.10          = $0.20
Upscaling:              10 × $0.02          = $0.20
BG removal (mixed):                         = $0.08
──────────────────────────────────────────────
Total:                                     ≈ $3.27
```

Default budget cap: **$12 USD**. LoRA setup is 77% of narrative cost but pays off across every scene.

---

## 12. Workspace Structure (v2)

```
~/book-illustration-engine/books/<slug>/
├── source.docx
├── style-ref.png
├── manifest.json          # v2 schema
├── costs.json
├── briefs/
│   └── scene-NN-<slug>.md
├── characters/            # NEW: populated by LoRA pipeline
│   ├── char-01-riya/
│   │   ├── refs/          # 5-8 NB Pro reference images
│   │   │   ├── front.jpeg
│   │   │   ├── side.jpeg
│   │   │   └── ...
│   │   └── lora.json      # weights URL, trigger word, config
│   └── char-02-buddy/
│       ├── refs/
│       └── lora.json
├── gens/
│   ├── scene-01-v1.jpeg           # original
│   ├── scene-01-v1-upscaled.png   # after upscale
│   └── scene-01-v2.jpeg           # retry (if needed)
├── final/
│   ├── scene-01-transparent.png   # 4096px, print-ready
│   └── scene-01-proof.png
└── logs/
    └── source.txt
```

---

## 13. What v2 Does NOT Do (Deferred)

1. Cross-book shared character library (v3 — data structured for it)
2. Icon grid generation (recorded + skipped)
3. Cross-reference resolution (recorded + skipped)
4. LLM inference for unmarked manuscripts
5. Generate-N-pick-best per scene (v2 does generate-1-judge-retry)
6. PDF layout / book composition
7. Web UI
8. Multi-book batch mode
9. Aesthetic taste judgment (only correctness)
10. Composition quality scoring
