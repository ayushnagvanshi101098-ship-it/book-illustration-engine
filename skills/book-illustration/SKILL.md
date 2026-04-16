---
name: book-illustration
description: End-to-end book illustration engine v2. Takes a children's book manuscript (.docx/.pdf) with inline "Illustration:" markers + style-ref image, and produces style-locked, character-consistent, print-ready background-removed illustration PNGs. Auto-detects recurring characters via character graph, trains FAL FLUX LoRAs for consistency, smart-routes each scene (FAL+LoRA for recurring characters, NB Pro for one-offs/anthology), auto-judges quality via Claude vision (5 criteria, up to 2 retries), upscales to 4K via FAL ESRGAN, removes backgrounds (FAL birefnet or local bgproof). Fully autonomous pipeline. TRIGGER when the user says "illustrate this book", "generate illustrations for <file>", "run the book illustration engine", or drops a book manuscript path in chat with a style ref. DO NOT TRIGGER for single-image generation (use nano-banana skill) or for non-book illustration work.
---

# Book Illustration Engine v2

You are orchestrating a book illustration pipeline. Your job is to take a manuscript file + a style reference image, extract illustration briefs, detect recurring characters, train LoRAs if needed, smart-route each scene to the best generation path, auto-judge quality, post-process to print resolution, and deliver final transparent PNGs.

## Engine location and helpers

The engine lives at `${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}`. All paths below use `$ENGINE` as a shorthand for that directory.

| Path | Purpose |
|---|---|
| `$ENGINE/bin/parse-doc.sh` | `.docx`/`.pdf` to numbered plain text |
| `$ENGINE/bin/gen-scene.sh` | One scene generation (Nano Banana Pro + edit-mode) |
| `$ENGINE/bin/gen-scene-fal.sh` | One scene generation (FAL FLUX + LoRA) |
| `$ENGINE/bin/gen-char-refs.sh` | Generate 5-8 reference images for one character via NB Pro |
| `$ENGINE/bin/train-lora.sh` | Submit refs to FAL LoRA training, poll until done |
| `$ENGINE/bin/upscale.sh` | Upscale image 2x via FAL Real-ESRGAN |
| `$ENGINE/bin/bg-remove-fal.sh` | Remove background via FAL birefnet |
| `$ENGINE/bin/bgproof.sh` | Local alpha extraction + dark-navy proof PNG (ImageMagick) |
| `$ENGINE/bin/fal-helpers.sh` | Shared FAL utilities (sourced by FAL scripts) |
| `$ENGINE/books/<slug>/` | Per-book workspace (created on first run) |

## Design spec

The canonical design is at `$ENGINE/docs/architecture.md`. If any instruction in this file is unclear, read the spec for context. Do NOT deviate from the spec without the user's explicit approval.

## High-level run flow

```
Step 1:  Bootstrap — create workspace, copy source and style-ref, init manifest (schema v2)
Step 2:  Parse — run parse-doc.sh to get numbered plain text
Step 3:  Extract briefs — grep and classify each Illustration: marker, extract character mentions
Step 4:  Build character graph — identify recurring vs one-off characters, determine per-scene routing
Step 5:  Train LoRAs — generate ref images + train FAL FLUX LoRA for each recurring character
Step 6:  Gate 1 — plan review — show full plan with characters, routing, costs; wait for user "go"
Step 7:  Generate scenes — smart-routed loop (FAL+LoRA or NB Pro per scene) with auto-judge
Step 8:  (Auto-judge is integrated into Step 7's generation loop)
Step 9:  Post-process — upscale 2x + bg-remove + proof composite for each generated scene
Step 10: Report — summarize what shipped with quality scores + routing breakdown
```

Gate 3 (budget overrun) fires mid-generation from Step 7 when the next gen would exceed the cap.

## v2 scope (what this engine does and does NOT do)

**DOES:**
- Process `.docx` and `.pdf` manuscripts
- Extract briefs from inline `Illustration:` or `Illustrations -` markers
- Classify briefs as hero_scene / icon_grid / cross_reference / author_supplied
- Build a character graph: identify unique characters, map appearances, classify recurring vs one-off
- Train FAL FLUX LoRAs for recurring characters (5-8 ref images per character)
- Smart-route each scene: FAL+LoRA (recurring characters) or NB Pro (one-offs/anthology)
- Auto-judge each generation via Claude vision (5 criteria), retry up to 2x if failed
- Upscale all generated scenes to 4096px via FAL Real-ESRGAN
- Remove backgrounds via FAL birefnet or local bgproof with smart fallback chain
- Track costs per operation type and enforce a budget cap (default $12 USD)
- Resume interrupted runs (v1 and v2 manifests)

**DOES NOT (v2):**
- Generate icon grids or mini-posters (skipped with reason)
- Resolve cross-references like "Same style as IF1" (skipped with reason)
- Share LoRA characters across different books (per-book isolation; v3)
- Fall back to LLM inference when no markers exist (halt with clear error)
- Handle non-.docx/.pdf formats
- Compose laid-out book PDFs
- Judge aesthetic taste or composition quality (only correctness)

---

## Step 1: Bootstrap — create the per-book workspace

When the user invokes the engine with a manuscript path + style-ref path, do the following:

### 1.1 Parse the invocation

Extract these from the user's message:
- `INPUT_DOC`: absolute path to the `.docx` or `.pdf` manuscript
- `STYLE_REF`: absolute path to the style-ref PNG/JPEG
- `BUDGET_USD_CAP`: numeric cap in USD (default: `12.00` if not specified)
- `BOOK_TITLE` (optional): if user provided one, use it; otherwise derive from the filename

Verify both files exist before proceeding. If either is missing, halt with a clear error.

### 1.2 Compute the book slug

The slug is derived from the book title using kebab-case rules:
1. Start with `BOOK_TITLE` or the basename of `INPUT_DOC` minus extension
2. Lowercase
3. Replace non-alphanumeric characters with `-`
4. Collapse runs of `-` into a single `-`
5. Strip leading/trailing `-`
6. Truncate to 60 characters

Example: `My Children's Book.docx` -> `my-childrens-book`

### 1.3 Check if workspace already exists

Let `WORKSPACE=~/book-illustration-engine/books/<slug>` (or `${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/books/<slug>` if the engine is installed elsewhere).

- If `WORKSPACE` does not exist: fresh run. Create it.
- If `WORKSPACE` exists and `manifest.json` exists with `schema_version: 1`: v1 resume. Read the manifest, add v2 fields with defaults (`book_type_detected: null`, `detection_reason: null`, `characters: []`), bump `schema_version` to 2. Identify scenes in `pending`/`failed` status and jump to Step 3 (brief extraction) with a resume banner.
- If `WORKSPACE` exists and `manifest.json` exists with `schema_version: 2`: v2 resume. Read the manifest, identify scenes in `pending`/`failed` status, and jump to the appropriate step based on state. If characters exist but no LoRAs trained, resume at Step 5. If LoRAs trained but scenes pending, resume at Step 6 (Gate 1).
- If `WORKSPACE` exists but `manifest.json` is missing or unreadable: manifest recovery mode. Tell the user, offer to rebuild from filenames + re-parse, or delete the workspace and start fresh.

### 1.4 Create the workspace layout (fresh run only)

Run:
```bash
ENGINE="${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}"
WORKSPACE="$ENGINE/books/<slug>"
mkdir -p "$WORKSPACE"/{briefs,characters,gens,final,logs}
cp "$INPUT_DOC" "$WORKSPACE/source.$(echo $INPUT_DOC | sed 's/.*\.//')"
cp "$STYLE_REF" "$WORKSPACE/style-ref.png"
```

### 1.5 Initialize manifest.json

Write to `$WORKSPACE/manifest.json`:
```json
{
  "book": {
    "slug": "<slug>",
    "title": "<book title>",
    "source": "source.<ext>",
    "style_ref": "style-ref.png",
    "created_at": "<current ISO-8601 timestamp with timezone>",
    "budget_usd_cap": 12.00,
    "schema_version": 2,
    "book_type_detected": null,
    "detection_reason": null
  },
  "characters": [],
  "scenes": [],
  "totals": {
    "gens_count": 0,
    "total_cost_usd": 0.0,
    "total_cost_inr_approx": 0.0
  },
  "run_history": [
    {
      "started_at": "<current ISO-8601 timestamp>",
      "finished_at": null,
      "status": "in_progress"
    }
  ]
}
```

If the user specified a custom budget cap, use that instead of 12.00.

### 1.6 Initialize costs.json

Write to `$WORKSPACE/costs.json`:
```json
{
  "book_slug": "<slug>",
  "budget_cap_usd": 12.00,
  "spent_usd": 0.0,
  "spent_inr_approx": 0.0,
  "usd_to_inr_rate": 83.50,
  "line_items": []
}
```

Valid line item types: `"lora_refs"`, `"lora_training"`, `"generation"`, `"upscale"`, `"bg_removal"`.

### 1.7 Announce readiness

Tell the user:
> Workspace created: `~/book-illustration-engine/books/<slug>/`
> Budget cap: $<cap> USD
> Next: parsing the manuscript and extracting illustration briefs...

Then proceed to Step 2.

---

## Step 2: Parse — extract plain text with line numbers

Run:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/parse-doc.sh" "$WORKSPACE/source.<ext>" -o "$WORKSPACE/logs/source.txt"
```

The output `source.txt` has every line prefixed with `NNNN: ` (zero-padded line number). This lets you cite exact source lines in the manifest.

If `parse-doc.sh` exits non-zero, halt with the script's stderr.

---

## Step 3: Extract briefs from the parsed text

### 3.1 Find all illustration markers

Use `grep -nE "^[0-9]+: Illustrations? ?[-:]" "$WORKSPACE/logs/source.txt"` to find every candidate marker line. This pattern matches `Illustration:`, `Illustrations:`, `Illustration -`, and `Illustrations -` (some authors use a dash instead of a colon).

For each match, note the line number (from the `NNNN:` prefix) as `source_line`.

### 3.2 Determine brief boundaries

For each marker, the brief starts at the marker line and continues until ANY of:
- The next blank line
- The next `Illustration:` / `Illustrations -` marker line
- The next section header (all-caps lines, "Page N", "Section header", "IN FOCUS N" style markers, "End of Page N")

Read the lines from marker_line to boundary_line. Strip the `NNNN: ` prefix from each line. Join with spaces. This is the `brief_text`.

### 3.3 Classify each brief into a type

Use your reasoning (not regex) to assign one of four types based on the content:

| Type | Signal phrases | Example |
|---|---|---|
| `hero_scene` | Describes a full scene with subjects, setting, action, mood | "A tall, thin man with a wooden flute marching along cobbled streets" |
| `icon_grid` | Mentions "icons", "small icon-line graphics", "mini poster", "the above bullets can have..." | "the above 4 bullet points can have small icon-line graphics" |
| `cross_reference` | "Same style as...", "Same as before...", references an earlier IF/ET/scene | "Same style as IF1 Exit ticket - only instead of..." |
| `author_supplied` | "see ref images", "ref images are given", "see attached" | "see ref images" |

When in doubt, default to `hero_scene` -- the user can correct at Gate 1.

### 3.4 Extract character mentions from each hero_scene brief

For each `hero_scene` brief, identify characters mentioned. This is a quick pass -- full graph building happens in Step 4. Record:
- Character name (or description if unnamed, e.g., "the old man with a cart")
- Brief physical description if present in the text

### 3.5 Generate a brief slug for each scene

Create a short human-readable slug from the first few content words of the brief (e.g., `rhythm-child`, `train-window`, `pied-piper`). This goes in the filename `scene-NN-<slug>.md`.

### 3.6 Write each brief to a markdown file

For each brief, write `$WORKSPACE/briefs/scene-NN-<slug>.md`:
```markdown
---
scene_id: scene-NN
source_line: <N>
type: <type>
book: <book-slug>
characters_mentioned:
  - name: "<character name>"
    description: "<brief physical description>"
  - name: "<another character>"
    description: "<description>"
---

<brief_text>
```

Scene numbers are assigned in source order, zero-padded to 2 digits (scene-01, scene-02, ...).

For non-hero-scene types (icon_grid, cross_reference, author_supplied), the `characters_mentioned` field can be an empty list.

### 3.7 Append scene entries to manifest.json

For each brief, add an entry to `manifest.json -> scenes[]`. For hero_scenes:
```json
{
  "id": "scene-NN",
  "source_line": 42,
  "type": "hero_scene",
  "status": "pending",
  "brief_file": "briefs/scene-NN-<slug>.md",
  "characters_featured": [],
  "route": null,
  "route_reason": null,
  "loras_used": [],
  "quality_judgments": [],
  "final_attempt": null,
  "upscaled": false,
  "upscale_size": null,
  "bg_removal_method": null,
  "gens": [],
  "final": null
}
```

For skipped types (icon_grid, cross_reference, author_supplied):
```json
{
  "id": "scene-NN",
  "source_line": 42,
  "type": "<type>",
  "status": "skipped",
  "skip_reason": "<reason>",
  "brief_file": "briefs/scene-NN-<slug>.md"
}
```

Skip reasons:
- `icon_grid` -> `"icon_grid type not supported in v2; handle manually in Photoshop"`
- `cross_reference` -> `"references another scene; not supported in v2"`
- `author_supplied` -> `"author supplies ref images; no generation needed"`

Use the `jq` command to update the manifest atomically:
```bash
jq --argjson new_scene '<scene_json>' '.scenes += [$new_scene]' "$WORKSPACE/manifest.json" > /tmp/manifest.tmp && \
mv /tmp/manifest.tmp "$WORKSPACE/manifest.json"
```

### 3.8 Handle the "no markers found" case

If `grep` returned zero matches, halt with:
> No `Illustration:` markers found in the manuscript. The engine requires explicit inline markers.
>
> Either:
> 1. Add `Illustration: <brief description>` lines to the manuscript where you want illustrations, then rerun.
> 2. Wait for a future version which will include an LLM inference fallback for unmarked manuscripts.
>
> Manifest has been initialized at `$WORKSPACE/manifest.json` -- you can delete the workspace or keep it for resume.

Do NOT proceed to Step 4 if there are zero hero scenes. Do NOT invoke any generation scripts.

---

## Step 4: Build Character Graph (NEW in v2)

After extracting all briefs, read ALL `hero_scene` briefs together and build a character graph. This is Claude reasoning, not a bash script. You must analyze all briefs holistically.

### 4.1 Identify unique characters across all briefs

Go through every `characters_mentioned` entry from every hero_scene brief. Group by semantic identity, not just name matching:
- "The girl with braids" and "Riya" in different briefs = same character if descriptions match
- "The tall man" in scene-01 and "the pied piper" in scene-03 = same character if context makes it clear
- When uncertain, keep them separate (splitting is safer than merging)

Assign IDs: `char-01`, `char-02`, etc.
Write a consolidated description for each character (merge details from all briefs where they appear).

### 4.2 Map appearances

For each unique character, record which scenes they appear in: `appears_in: ["scene-01", "scene-03", ...]`

### 4.3 Classify recurring vs one-off

- A character is **recurring** if they appear in 2+ scenes -> `is_recurring: true`, `lora_status: "pending"`
- A character is **one-off** if they appear in exactly 1 scene -> `is_recurring: false`, `lora_status: "skip"`

### 4.4 Determine per-scene routing

For each hero_scene:
- If the scene features ANY recurring character -> `route: "fal"`, `route_reason: "recurring characters: <names>"`
- If the scene features zero recurring characters -> `route: "nano_banana"`, `route_reason: "no recurring characters"`

### 4.5 Detect book type

- If ANY character is recurring -> `book_type_detected: "narrative"`, `detection_reason: "<N> recurring characters across <M> scenes"`
- If zero characters are recurring -> `book_type_detected: "anthology"`, `detection_reason: "no recurring characters detected"`

### 4.6 Update manifest.json

Populate `characters[]` array:
```json
{
  "characters": [
    {
      "id": "char-01",
      "name": "Riya",
      "description": "8-year-old girl with two braids, blue school uniform, curious expression",
      "appears_in": ["scene-01", "scene-03", "scene-05", "scene-07"],
      "is_recurring": true,
      "lora_status": "pending",
      "trigger_word": null,
      "lora_weights_url": null,
      "lora_config": null,
      "ref_images": [],
      "training_cost_usd": 0.0
    },
    {
      "id": "char-02",
      "name": "the balloon seller",
      "description": "elderly man with white beard, torn vest, red cart full of colorful balloons",
      "appears_in": ["scene-04"],
      "is_recurring": false,
      "lora_status": "skip",
      "trigger_word": null,
      "lora_weights_url": null,
      "lora_config": null,
      "ref_images": [],
      "training_cost_usd": 0.0
    }
  ]
}
```

Set `book.book_type_detected` and `book.detection_reason`.
Set each hero_scene's `route`, `route_reason`, and `characters_featured` (list of char-IDs).

Use atomic jq writes for all manifest updates.

### 4.7 Anthology shortcut

If `book_type_detected == "anthology"` (zero recurring characters):
- Skip Step 5 entirely (no LoRA training needed)
- All hero_scenes already have `route: "nano_banana"`
- Proceed directly to Step 6 (Gate 1)

Tell the user:
> Anthology detected: no recurring characters found. All scenes will use NB Pro edit-mode.
> Skipping LoRA training. Proceeding to plan review...

---

## Step 5: Train LoRAs for Recurring Characters (NEW in v2)

This step only runs for narrative/hybrid books with at least one recurring character.

### Budget pre-check before training

Estimate total LoRA cost: `recurring_count * 1.65` (refs + training per character).
Verify `spent_usd + lora_estimate <= budget_cap`. If not, warn the user and ask to raise cap or skip LoRA training (all scenes fall back to NB Pro).

### For each character where `is_recurring: true` and `lora_status: "pending"`:

#### Step 5a: Generate character reference images

Compute a name slug from the character name (lowercase, hyphens, e.g., `riya`, `buddy`, `ms-sharma`).

Run:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/gen-char-refs.sh" \
  --character-desc "<consolidated character description>" \
  --character-id <char-id> \
  --style-ref "$WORKSPACE/style-ref.png" \
  --output-dir "$WORKSPACE/characters/<char-id>-<name-slug>/refs/"
```

The script generates 5-8 reference images (varying pose/angle/expression) and outputs JSON on stdout with the list of generated files and costs.

After success:
- Parse stdout JSON to get file paths and per-image cost
- Update `costs.json`: append a `lora_refs` line item:
  ```json
  {
    "ts": "<ISO-8601>",
    "type": "lora_refs",
    "character": "<char-id>",
    "count": 6,
    "cost_usd": 0.90
  }
  ```
- Update manifest: set `characters[N].ref_images` to the list of generated file paths (relative to workspace)
- Update `costs.json.spent_usd` and `spent_inr_approx`
- Update `manifest.totals`

If gen-char-refs.sh fails: retry once after 10s. Still fails -> mark `characters[N].lora_status = "lora_failed"`, continue to next character.

#### Step 5b: Train LoRA

Compute trigger word: lowercase name slug + `_char` suffix (e.g., `riya_char`, `buddy_char`, `ms_sharma_char`).

Run:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/train-lora.sh" \
  --character-id <char-id> \
  --trigger-word "<trigger_word>" \
  --images-dir "$WORKSPACE/characters/<char-id>-<name-slug>/refs/" \
  --output "$WORKSPACE/characters/<char-id>-<name-slug>/"
```

The script submits images to FAL `fal-ai/flux-lora-fast-training`, polls every 15s until complete (typically 2-5 minutes), and on success saves `lora.json` with weights URL + config. Outputs JSON on stdout.

After success:
- Parse stdout JSON to get `weights_url`, `training_cost_usd`
- Update manifest character entry:
  ```json
  {
    "lora_status": "trained",
    "trigger_word": "<trigger_word>",
    "lora_weights_url": "<url from lora.json>",
    "lora_config": "characters/<char-id>-<name-slug>/lora.json",
    "training_cost_usd": 0.72
  }
  ```
- Update `costs.json`: append a `lora_training` line item:
  ```json
  {
    "ts": "<ISO-8601>",
    "type": "lora_training",
    "character": "<char-id>",
    "cost_usd": 0.72
  }
  ```
- Update `costs.json.spent_usd` and `spent_inr_approx`
- Update `manifest.totals`

If train-lora.sh fails: retry once after 30s. Still fails -> mark `characters[N].lora_status = "lora_failed"`.

If training times out (>10 minutes with no completion): mark `characters[N].lora_status = "lora_timeout"`.

#### Step 5c: Handle failed LoRAs

Characters with `lora_status` of `"lora_failed"` or `"lora_timeout"`:
- Their scenes automatically fall back to NB Pro at generation time
- Update those scenes: `route: "nano_banana"`, `route_reason: "LoRA failed for <character name>, falling back to NB Pro"`
- This degraded state is shown at Gate 1 so the user can decide whether to proceed

#### Step 5d: Status message per character

After each character (success or failure):
```
[<i>/<N>] char-NN (<name>): <status>  ($<spent>/$<budget>)
```
Where status is `trained` or `lora_failed: <error>` or `lora_timeout`.

---

## Step 6: Gate 1 — Plan Review (Enhanced)

After character graph + routing decisions (and LoRA training if applicable), present the full plan and wait for approval. Do NOT generate any scenes before Gate 1 is resolved.

### 6.1 Compute cost estimate

Calculate estimated remaining cost:
- FAL generations: `fal_scene_count * 0.06`
- NB Pro generations: `nb_scene_count * 0.16`
- Upscaling: `hero_scene_count * 0.02`
- BG removal (FAL): `fal_scene_count * 0.01`
- Retries budget: `hero_scene_count * 0.20 * avg_retry_cost` (estimate ~20% retry rate)
- Already spent (from LoRA training in Step 5): read from `costs.json.spent_usd`

### 6.2 Print the plan

Output format:
```
Book: "<title>"
Type detected: <NARRATIVE|ANTHOLOGY> (<detection_reason>)

CHARACTERS
  char-01  Riya (8yo girl, braids, blue uniform)           -> scenes 1,3,5,7  -> TRAINED
  char-02  Buddy (golden retriever puppy)                  -> scenes 1,5      -> TRAINED
  char-03  the balloon seller (old man, red cart)           -> scene 4 only    -> SKIP (one-off)
  char-04  Ms. Sharma (teacher, grey sari)                 -> scenes 2,7      -> LORA FAILED
  ...

SCENES - GENERATION PLAN
  scene-01  line 12   Riya meets Buddy at school gate        FAL+LoRA  [char-01, char-02]
  scene-02  line 34   Ms. Sharma writes on blackboard        NB Pro    [LoRA failed for Ms. Sharma]
  scene-03  line 56   Riya discovers the hidden garden        FAL+LoRA  [char-01]
  scene-04  line 78   Balloon seller at the mela             NB Pro    [no recurring chars]
  scene-08  line 120  (icon_grid)                            SKIP: not supported
  ...

COST ESTIMATE
  LoRA refs:            2 chars x 6 refs x $0.15      = $1.80
  LoRA training:        2 chars x ~$0.75              = $1.50
  FAL generations:      5 scenes x ~$0.06             = $0.30
  NB Pro generations:   3 scenes x ~$0.16             = $0.48
  Upscaling:            8 scenes x ~$0.02             = $0.16
  BG removal (FAL):     5 scenes x ~$0.01             = $0.05
  Retries (budget):     ~2 retries                    = $0.12
  ------------------------------------------------
  Already spent:                                       $3.30 (LoRA training)
  Estimated remaining:                                 $1.11
  Estimated total:                                     $4.41
  Budget cap:                                          $12.00

Proceed? Reply "go", or:
  - "skip char-NN"            -> don't use LoRA, scenes fall back to NB Pro
  - "skip scene-NN"           -> mark scene skipped
  - "reroute scene-NN fal"    -> force FAL route (warn if no LoRA for its characters)
  - "reroute scene-NN nb"     -> force NB Pro route
  - "swap scene-NN to hero_scene"  -> reclassify a skipped scene
  - "raise cap to N"          -> adjust budget
  - "cancel"                  -> halt the run
```

For **anthology** books (zero characters), the CHARACTERS section shows "No recurring characters detected" and all scenes show "NB Pro". The LoRA cost lines show $0.00.

### 6.3 Handle resume case

If this is a resume (workspace already existed with prior run_history entries), prefix the plan with:
```
Resuming existing run.
Previous status: <X> final, <Y> pending, <Z> failed, <W> quality_failed.
```
And show only the pending/failed scenes in the "will generate" list.

### 6.4 Parse user response

Accept these responses:

| Response | Action |
|---|---|
| `go` | Proceed to Step 7 |
| `cancel` | Update manifest.run_history[last].status = "cancelled", halt |
| `skip char-NN` | Set character's scenes to `route: "nano_banana"`, `route_reason: "user skipped LoRA"`, re-show plan |
| `skip scene-NN` | Update scene status to `skipped`, reason `"user_requested"`, re-show plan |
| `reroute scene-NN fal` | Change scene route to `fal`, warn if no trained LoRA for its characters, re-show plan |
| `reroute scene-NN nb` | Change scene route to `nano_banana`, re-show plan |
| `swap scene-NN to hero_scene` | Update scene type to `hero_scene`, status to `pending`, re-show plan |
| `raise cap to <N>` | Update `manifest.book.budget_usd_cap` and `costs.json.budget_cap_usd`, re-show plan |

Do NOT accept any other commands. If the user says something off-script, ask them to use one of the listed forms or cancel.

### 6.5 Budget safety check before proceeding

After user says "go", verify `estimated_total <= budget_usd_cap`. If not, fire Gate 3 before generating any scenes.

### 6.6 Transition to generation

Once "go" is received and budget is safe, print:
```
Starting generation of <H> hero scenes...
Estimated time: ~<time estimate> and cost: $<est_remaining>.
```
Proceed to Step 7.

---

## Step 7: Generate Scenes (Smart-Routed with Auto-Judge)

Iterate over all scenes in `manifest.scenes[]` where `type == "hero_scene"` and `status == "pending"`. Process in scene order (scene-01, scene-02, ...).

### 7.1 Budget pre-check (before each scene)

Read `costs.json` and verify:
- FAL route: `spent_usd + 0.06 <= budget_cap_usd`
- NB Pro route: `spent_usd + 0.16 <= budget_cap_usd`

If the next generation would exceed the cap, fire Gate 3 (see dedicated section below). Do NOT skip this check.

### 7.2 Route and generate

Read the scene's `route` field from manifest.

**If `route == "fal"`:**

Build the LoRA arguments. For each character in the scene's `characters_featured` that has `lora_status: "trained"`:
- Read the character's `trigger_word` and `lora_weights_url` from manifest
- Build flag: `--lora "<char-id>:<trigger-word>:<lora-weights-url>"`

Run:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/gen-scene-fal.sh" \
  --brief "$WORKSPACE/briefs/<brief-file>" \
  --style-ref "$WORKSPACE/style-ref.png" \
  --output "$WORKSPACE/gens/<scene-id>-v<version>.jpeg" \
  --lora "<char-id>:<trigger-word>:<weights-url>" \
  --lora "<char-id>:<trigger-word>:<weights-url>"
```

Multiple `--lora` flags for scenes with multiple recurring characters.

Cost per FAL generation: ~$0.06.

**If `route == "nano_banana"`:**

Run (same as v1):
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/gen-scene.sh" \
  --brief "$WORKSPACE/briefs/<brief-file>" \
  --style-ref "$WORKSPACE/style-ref.png" \
  --output "$WORKSPACE/gens/<scene-id>-v<version>.jpeg"
```

Cost per NB Pro generation: ~$0.16 (at 2K resolution).

### 7.3 Handle generation outcome

| Outcome | Response |
|---|---|
| Script exits 0, file exists, is a valid JPEG | Proceed to auto-judge (7.4) |
| Script exits non-zero with API/network error | Retry up to 3x with 2s/8s/30s backoff, then mark scene `failed` |
| Script exits 0 but file missing or < 100KB | Treat as failure, mark scene `failed`, continue to next scene |

### 7.4 Auto-Judge via Claude Vision

After each successful generation, judge the image quality using Claude vision. This is Claude reasoning, not a bash script.

**Examine the following images together in one assessment:**
1. The generated scene image (`$WORKSPACE/gens/<scene-id>-v<version>.jpeg`)
2. The style-ref image (`$WORKSPACE/style-ref.png`)
3. If this is a FAL route scene: the character reference images from `$WORKSPACE/characters/<char-id>-<name-slug>/refs/` for each featured character

**Read the brief text** from the brief file.

**Evaluate 5 criteria (pass/fail each):**

| # | Check | What it means | Fail example |
|---|---|---|---|
| 1 | Subject match | Right characters/objects/setting present as described in brief | Brief says "girl on swing", image shows boy on bench |
| 2 | Style fidelity | Art style matches style-ref (medium, linework, color palette) | Style-ref is watercolor, output looks 3D rendered |
| 3 | Anatomy/coherence | No broken hands, extra limbs, melted faces, spatial nonsense | Six fingers, floating head, impossible perspective |
| 4 | Artifact check | No text artifacts, watermarks, banding, color blowout | Random text in sky, visible watermark |
| 5 | Character match | LoRA character matches trained refs (FAL route only) | Riya has wrong hair color or completely different face |

For NB Pro route scenes, skip criterion 5 (character match) since there are no LoRA refs to compare against.

**Produce a structured judgment:**
```json
{
  "pass": false,
  "failures": ["anatomy"],
  "details": "Child has 6 fingers on left hand",
  "retry_hint": "Add 'anatomically correct hands, five fingers' emphasis to prompt"
}
```

**Retry logic:**

- **Pass (all criteria):** Mark scene as `"generated"`, record judgment, proceed to next scene.
- **Fail, attempt 1 of 3:** Append `retry_hint` to the generation prompt. Regenerate with incremented version number (v2, v3). Re-judge.
- **Fail, attempt 2 of 3:** Same retry logic with accumulated hints.
- **Fail, attempt 3 of 3 (final attempt):** Mark scene `"quality_failed"`. Examine all 3 generated versions. Pick the least-bad one (the one with fewest/least-severe failures). Set `chosen: true` on that version. Record all judgments.

Each retry attempt costs against the budget (budget pre-check runs before each retry too).

### 7.5 Update manifest and costs after each attempt

After each generation attempt (whether pass, fail-retry, or final-fail):

Append to `scenes[N].gens[]`:
```json
{
  "version": 1,
  "path": "gens/scene-NN-v1.jpeg",
  "cost_usd": 0.06,
  "chosen": true,
  "notes": ""
}
```

Append to `scenes[N].quality_judgments[]`:
```json
{
  "attempt": 1,
  "pass": true,
  "failures": [],
  "details": "All checks passed",
  "retry_hint": null
}
```

Update costs.json -- append a `generation` line item:
```json
{
  "ts": "<ISO-8601>",
  "type": "generation",
  "scene": "scene-NN",
  "version": 1,
  "route": "fal",
  "model": "flux-lora",
  "loras_used": ["char-01", "char-03"],
  "cost_usd": 0.06
}
```

For NB Pro route scenes:
```json
{
  "ts": "<ISO-8601>",
  "type": "generation",
  "scene": "scene-NN",
  "version": 1,
  "route": "nano_banana",
  "model": "pro",
  "cost_usd": 0.16
}
```

For retry attempts, add a `"note"` field: `"retry: <failure reasons>"`.

Update `costs.json.spent_usd` and `spent_inr_approx`.
Update `manifest.totals.gens_count` and `manifest.totals.total_cost_usd`.

Set `scenes[N].status`:
- All criteria pass -> `"generated"`
- Quality failed after 3 attempts -> `"quality_failed"`
- Generation script failures (API errors) -> `"failed"`

Set `scenes[N].final_attempt` to the chosen version number.

**All manifest/costs writes must be atomic.** Use the write-temp + rename pattern:
```bash
jq '<update_expression>' "$WORKSPACE/manifest.json" > /tmp/manifest.tmp && \
mv /tmp/manifest.tmp "$WORKSPACE/manifest.json"
```

### 7.6 Status message per scene

After each scene is fully resolved (generated, quality_failed, or failed), tell the user:
```
[<i>/<H>] scene-NN: <status>  ($<spent_usd>/$<budget>)
```
Where status is:
- `generated (attempt 1, passed)`
- `generated (attempt 2, passed after retry: anatomy)`
- `quality_failed (best of 3 attempts used)`
- `failed: <error>`

### 7.7 API/network retry logic

If the generation script fails with an error that looks like network/API/rate-limit:
- Attempt 1 fails -> wait 2s -> retry
- Attempt 2 fails -> wait 8s -> retry
- Attempt 3 fails -> wait 30s -> retry
- Attempt 4 fails -> mark scene `failed`, record last error in `scenes[N].last_error`, continue to next scene

This is separate from quality retries. Quality retries are about the image content being wrong. API retries are about the script failing to produce any image at all.

---

## Gate 3: Budget Overrun (triggered mid-run)

This gate fires from Step 7.1 (or Step 5 budget pre-check) when the next operation would push spend above the cap.

### Compute state

```
pending_scenes = count(scenes where type=hero_scene and status=pending)
est_remaining = pending_scenes * (avg_cost_per_scene based on route mix)
```

### Prompt the user

```
Budget warning: $<spent> / $<cap> spent (<percent>%)
<pending_scenes> scenes still pending. Estimated remaining cost: $<est_remaining>.

Options:
  (a) raise cap to $<suggested new cap>
  (b) stop here, mark remaining as pending (resume later)
  (c) continue anyway (may exceed cap)
```

### Parse response

- `a` or `raise cap to N` -> update cap in manifest + costs.json, continue
- `b` or `stop` -> mark run_history[last].status = "paused", print partial summary, halt
- `c` or `continue` -> flip an `override_cap` flag for this run, continue

Do NOT loop on invalid responses -- if the user says something unexpected, treat it as `b` (safest default).

---

## Step 9: Post-Process — Upscale + BG Remove + Proof

After all hero scenes have been through Step 7, loop over scenes where `status == "generated"` or `status == "quality_failed"` (quality_failed scenes still get post-processed using the best/chosen attempt).

For each scene, identify the chosen generation version from `scenes[N].gens[]` (the one with `chosen: true`). Let `CHOSEN_PATH` be the path of that file.

### 9.1 Upscale to print resolution

Run:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/upscale.sh" \
  --input "$WORKSPACE/<CHOSEN_PATH>" \
  --output "$WORKSPACE/gens/<scene-id>-v<chosen>-upscaled.png"
```

This calls FAL Real-ESRGAN, upscaling 2048 -> 4096px. Output is PNG (lossless). At 300 DPI this gives ~13.6 inches (A4/Letter ready).

Cost: ~$0.02 per image.

Update `costs.json`: append an `upscale` line item:
```json
{
  "ts": "<ISO-8601>",
  "type": "upscale",
  "scene": "scene-NN",
  "cost_usd": 0.02
}
```

Update `costs.json.spent_usd` and `spent_inr_approx`.

If upscale.sh fails: skip upscaling, continue with original resolution file. Set `scenes[N].upscaled = false`. Log:
```
scene-NN: upscale failed, using original resolution
```

If upscale succeeds: set `scenes[N].upscaled = true`, `scenes[N].upscale_size = 4096`.

### 9.2 Background removal (route-dependent fallback chain)

Let `UPSCALED_PATH` be the upscaled file (or the original if upscale failed).

**If scene route was `"fal"`:**

Use FAL birefnet (better at hair/fur edges, semi-transparent watercolor bleeds):
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/bg-remove-fal.sh" \
  --input "$WORKSPACE/<UPSCALED_PATH>" \
  --output "$WORKSPACE/gens/<scene-id>-v<chosen>-transparent.png"
```

Cost: ~$0.01 per image. Update costs.json with `bg_removal` line item.

If bg-remove-fal.sh fails: mark `scenes[N].bgproof_failed = true`, keep the upscaled PNG, flag in report. Set `bg_removal_method: "failed"`.

If success: set `bg_removal_method: "fal_birefnet"`.

**If scene route was `"nano_banana"`:**

First try local bgproof (free):
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/bgproof.sh" "$WORKSPACE/<UPSCALED_PATH>"
```

bgproof.sh writes `-transparent.png` and `-proof.png` files alongside the input.

If bgproof succeeds: set `bg_removal_method: "bgproof"`. No cost (local ImageMagick).

If bgproof fails (non-zero exit or output missing, typically due to colored sky): fall back to FAL birefnet:
```bash
"${BOOK_ENGINE_HOME:-$HOME/book-illustration-engine}/bin/bg-remove-fal.sh" \
  --input "$WORKSPACE/<UPSCALED_PATH>" \
  --output "$WORKSPACE/gens/<scene-id>-v<chosen>-transparent.png"
```

If FAL fallback succeeds: set `bg_removal_method: "bgproof_fal_fallback"`. Update costs.json (~$0.01).

If FAL fallback also fails: mark `scenes[N].bgproof_failed = true`, keep the upscaled PNG, flag in report.

### 9.3 Move to final/ and generate proof

Move the transparent PNG to final/:
```bash
cp "$WORKSPACE/gens/<scene-id>-v<chosen>-transparent.png" "$WORKSPACE/final/<scene-id>-transparent.png"
```

Generate the navy proof composite:
```bash
W=$(magick identify -format '%w' "$WORKSPACE/final/<scene-id>-transparent.png")
H=$(magick identify -format '%h' "$WORKSPACE/final/<scene-id>-transparent.png")
magick -size "${W}x${H}" "xc:#1a1a2e" "$WORKSPACE/final/<scene-id>-transparent.png" -composite "$WORKSPACE/final/<scene-id>-proof.png"
```

If bgproof.sh was used (NB Pro route, success path), it already created `-transparent.png` and `-proof.png` alongside the input. In that case, move those files to final/ instead:
```bash
mv "$WORKSPACE/gens/<scene-id>-v<chosen>-upscaled-transparent.png" "$WORKSPACE/final/<scene-id>-transparent.png"
mv "$WORKSPACE/gens/<scene-id>-v<chosen>-upscaled-proof.png" "$WORKSPACE/final/<scene-id>-proof.png"
```

The original JPEG and upscaled PNG stay in `gens/` as preservation copies.

### 9.4 Stamp 300 DPI + generate CMYK TIFF

After the transparent PNG is in final/, stamp it at 300 DPI and create a CMYK TIFF for print production:

```bash
# Set 300 DPI on the transparent PNG
magick "$WORKSPACE/final/<scene-id>-transparent.png" \
  -units PixelsPerInch -density 300 \
  "$WORKSPACE/final/<scene-id>-transparent.png"

# Generate CMYK TIFF for print
magick "$WORKSPACE/final/<scene-id>-transparent.png" \
  -colorspace CMYK -units PixelsPerInch -density 300 \
  "$WORKSPACE/final/<scene-id>-cmyk.tiff"
```

This produces two final versions per scene:
- `<scene-id>-transparent.png` — RGB with alpha, 300 DPI (for digital layout, compositing)
- `<scene-id>-cmyk.tiff` — CMYK, 300 DPI (for print production, offset printing)

Both are always generated. No cost (local ImageMagick).

### 9.5 Update manifest

For each scene after post-processing:
```json
{
  "status": "final",
  "upscaled": true,
  "upscale_size": 4096,
  "bg_removal_method": "fal_birefnet",
  "final": {
    "transparent": "final/<scene-id>-transparent.png",
    "cmyk": "final/<scene-id>-cmyk.tiff",
    "proof": "final/<scene-id>-proof.png"
  }
}
```

For scenes where bg removal failed:
```json
{
  "status": "generated",
  "upscaled": true,
  "upscale_size": 4096,
  "bg_removal_method": "failed",
  "bgproof_failed": true,
  "final": null
}
```

### 9.6 Status message per scene

After each scene's post-processing:
```
[<i>/<H>] scene-NN post-processed: upscaled to 4096px, bg removed via <method>
```
Or on failure:
```
scene-NN: bg removal failed (both methods) - keeping upscaled PNG, no transparent version
```

---

## Step 10: Final Report

After all hero scenes have been processed through generation and post-processing, generate the final report.

### 10.1 Update run_history

Set `manifest.run_history[last].finished_at = <now>` and `status`:
- `"completed"` if all hero scenes are `final`
- `"partial"` if any scenes are `failed`, `quality_failed`, or still `pending`

### 10.2 Compute summary stats

Read manifest and costs.json to compute:
- `final_count`: scenes with status `"final"`
- `quality_failed_count`: scenes with status `"quality_failed"` that were post-processed
- `failed_count`: scenes with status `"failed"` (generation errors)
- `bgproof_failed_count`: scenes where `bgproof_failed == true`
- `fal_route_count`: scenes with route `"fal"`
- `nb_route_count`: scenes with route `"nano_banana"`
- `total_gens`: total generation attempts (including retries)
- `retry_count`: generations where attempt > 1
- `first_attempt_pass_rate`: percentage of scenes that passed on first attempt
- Cost breakdown by type: sum costs.json line_items grouped by `type`
- `lora_trained_count`: characters with `lora_status: "trained"`
- `lora_failed_count`: characters with `lora_status: "lora_failed"` or `"lora_timeout"`

### 10.3 Print summary

```
Engine run complete: <slug>

  Book type:              <NARRATIVE|ANTHOLOGY> (<detection_reason>)
  Characters trained:     <N> LoRAs (<M> failed)

  Hero scenes processed:  <final_count>/<hero_count> final
                          <quality_failed_count> quality_failed (best attempt used)
                          <failed_count> failed (generation errors)
                          <bgproof_failed_count> bg removal failed (upscaled PNG kept)
  Routing breakdown:      <fal_count> via FAL+LoRA, <nb_count> via NB Pro
  Skipped (by type):      <skip_count> total (icon_grid: <N>, cross_ref: <N>, author_supplied: <N>)

  Total generations:      <total_gens> (including <retry_count> retries)
  Quality pass rate:      <first_attempt_pass_rate>% first-attempt pass

  Total cost:             $<total_usd> (~<total_inr>)
    LoRA refs:            $<X>
    LoRA training:        $<X>
    Generation:           $<X>
    Upscaling:            $<X>
    BG removal:           $<X>
  Budget cap:             $<cap>

  Workspace:  ~/book-illustration-engine/books/<slug>/
  Final PNGs: ~/book-illustration-engine/books/<slug>/final/

  Next steps:
    - Review final/*-proof.png against style-ref.png
    - For quality_failed scenes, consider manual rerun with adjusted prompt
    - For bgproof-failed scenes, handle manually with rembg or Photoshop
    - For failed scenes, rerun manually with the appropriate gen script
```

### 10.4 Offer to open the final folder

Ask: "Open the final folder in Finder? (y/n)"

If yes: `open "$WORKSPACE/final/"`

---

## Error handling summary

| Situation | Response |
|---|---|
| Input file missing | Halt at bootstrap with clear error |
| No `Illustration:` markers | Halt after Step 3 with clear message (see 3.8) |
| `parse-doc.sh` fails | Halt with the script's stderr |
| `FAL_KEY` not set or invalid | Halt entire run with clear message: "FAL_KEY not configured. See .env.example for setup instructions." |
| `gen-char-refs.sh` fails | Retry once, then mark character `lora_failed`, continue |
| `train-lora.sh` fails | Retry once after 30s, then mark character `lora_failed`, continue |
| LoRA training timeout (>10 min) | Mark character `lora_timeout`, same fallback |
| Generation API failures | Retry 3x backoff (2s/8s/30s), then mark scene `failed` and continue |
| Auto-judge fails image | Retry up to 2x with hint, then pick best of 3 and mark `quality_failed` |
| `upscale.sh` fails | Skip upscale, use original resolution, set `upscaled: false` |
| bgproof fails (colored sky) | Fall back to FAL birefnet |
| FAL birefnet fails | Mark `bgproof_failed`, keep upscaled PNG, flag in report |
| Budget cap hit mid-run | Fire Gate 3 |
| User kills mid-run | Next invocation reads manifest, resumes from pending/failed |
| Corrupted manifest | Offer to rebuild from `gens/`, `final/`, and source doc |
| Source doc edited since last run | Re-parse briefs, compare to brief_files, mark changed briefs pending |
| v1 manifest detected | Add v2 fields with defaults, bump schema_version, resume cleanly |

## Things NEVER to do

- Do NOT call `gen-scene.sh` or `gen-scene-fal.sh` for `icon_grid`, `cross_reference`, or `author_supplied` scenes
- Do NOT proceed past Gate 1 without explicit user "go"
- Do NOT delete anything in `gens/` -- all generation history is preserved
- Do NOT modify the source document in the workspace (it is copy-on-bootstrap, read-only after)
- Do NOT push the git repo (local commits only per user preference)
- Do NOT hardcode, log, or paste API keys. FAL_KEY is read from environment by the scripts.
- Do NOT train LoRAs for one-off characters (1 scene only)
- Do NOT skip the auto-judge step. Every generation must be judged before post-processing.
- Do NOT skip budget pre-checks. Every generation attempt (including retries) must pass the budget gate.
- Do NOT call `gen-character-sheet.sh` -- it is a v1 stub and will exit with error
