# Render pipeline operations (turbo-carnival)

How a render actually gets from this repo to ComfyUI, the tools that inspect and drive
it, and the traps that have each cost a batch.

## The workflow's source of truth is a FILE, not the database column

`pipeline_steps.comfy_workflow_json` is a Postgres text column with **no git history**.
That is how an identity prompt got silently rewritten — an agent produced a "clean"
variant with the body/wardrobe language swapped for "fully clothed, modest" and wired
production at it — and nothing could diff it.

- Keep each workflow in the repo: `comfy_workflows/<slug>/stepN_<name>.json`, the
  ComfyUI **API** graph (`{node_id => {class_type, inputs}}`), written with sorted keys
  and indent so a one-field change is a one-line diff.
- Load it with `rake "pipeline:register[<dir>,<pipeline-name>]"`
  (`lib/tasks/pipeline_workflows.rake`). Idempotent, and **the file wins** on re-run —
  that is the point. It refuses a UI-format export (the text column would accept one and
  ComfyUI would reject it mid-render) and prints the node count + placeholder inventory.
- The DB is a **load target**. Never hand-edit a step's workflow in SQL.

## The placeholder system (three substitution passes)

A stored workflow is a template; `{{token}}` reaches ComfyUI through three separate
passes in three different classes:

1. `BuildJobPayload#replace_template_variables` — string-level, **before** the JSON is
   parsed. Map = run variables + `prompt` + `run_name` + system (`timestamp`,
   `timestamp_ms`, `random`) + `parent_image_path`. Values escaped via `to_json[1..-2]`.
2. `PipelinePromptSafety.sanitize_workflow` — the single choke point that rewrites
   stored text. Treat it as a **legality** floor only, not a taste filter.
3. `SubmitJob#apply_job_variables` — resolves `"{{job_id}}"` and `"{{auto_seed}}"`.
   `auto_seed` = `pipeline_run.variables["seed"] || 1000000` **plus `job.id`**.

Gotchas:
- Pass 3 matches only the **quoted** JSON form (`"{{auto_seed}}"`), so a job-id/seed
  token embedded inside a longer string is silently never substituted.
- An unresolved token does not error: ComfyUI receives the token text as the prompt.
- Node inputs that are 2-element lists are **wires**; only a bare string is text.
- A `Text Multiline` value that reaches ComfyUI as null stringifies to the literal
  `None` and renders as *no scene at all* rather than as an error. Fail loudly instead.
- Provenance is a red line: `base_model` / `seed` / `prompt_hash` / `quality_metrics`
  on every render, plus a synthetic mark that reaches the published asset.

## The text surface: which node drives what

Five text inputs decide a render. Knowing which is which is the difference between a fix
and a plausible story, because the same token in two nodes does two different jobs.

| node | feeds | job |
|---|---|---|
| `111` + `88` (concatenated) | pony `CLIPTextEncode` -> `KSampler` | **the base image** |
| `50` | flux `FluxGuidance` -> guider -> `SamplerCustomAdvanced` | **the FACE inpaint** |
| `86` | flux guider -> `SamplerCustomAdvanced` | **the HANDS inpaint** |
| `79` | `KSampler` negative | negative |
| `16` / `24` CLIPSeg `prompt` | `ApplyCLIPSeg` | head / hand masks |

flux1-dev is loaded **only** for the face and hands passes; the base image is the pony
checkpoint. The face pass crops to the head mask, re-renders at low denoise, and
composites the crop back into the original.

- **The face node must hold a static portrait prompt, never the scene.** Scene text in the
  face node renders the *scene* into the face crop, so you get a kitchen where the face
  should be. The scene belongs in the base-render node only.
- Therefore the scene token must reach **one** node. Tokenising `{{prompt}}` into both a
  scene node and the face node is a latent bug that only ever shows up as a strange face.
- Identity facts get duplicated across the identity block and the static face prompt, so a
  persona-foreign word can land in one and not the other (a `blonde` from another persona
  appeared in the face prompt while the identity block said `brunette`). Running more than
  one persona makes this a certainty: single-source identity facts rather than duplicating
  hardcoded strings per node.
- The gaze/mood line is a **visual instruction**, not filler: `Admiring, affectionate,
  obedient, submissive` yields a face slightly turned down, brows raised, pupils high in
  the socket -- i.e. looking slightly up. Do not "clean it up" as personality fluff.
- **Wardrobe is scene text, never a LoRA.** Every wardrobe LoRA in the current stack is
  `on:false`, so clothing comes entirely from the scene sentence. Anatomy leaks are a
  *checkpoint* characteristic -- measured: two checkpoints, identical prompt and identical
  seed, one leaked -- so the text lever is wardrobe wording that covers the torso, not a
  hunt for an explicit word (there is not one anywhere in the workflow).
- **Wardrobe and pose multiply, so check the wording against the camera.** A cover written as
  front-only (`the bib covering her chest completely ... hanging flat over the front of her
  torso; bare back and shoulders, bare legs`) combined with a from-behind pose leaves the rear
  both bare *and in frame*, and the render ships with an uncovered behind. Cover wording must
  describe the surfaces the chosen camera can actually see; a front-only cover is safe only with
  a front/side pose, and a suppressing negative is cheap insurance either way.
- **Holding a count takes BOTH halves -- and the POSITIVE is the half that does the work.** The
  negative needs `2girls, multiple girls, two women`, but adding those guards alone left the
  two-woman failure recurring across separate scene variants; it only stopped once `1girl, solo`
  was added to the identity block's positive prefix. The negatives suppress a *concept*, the
  positive asserts the *count*, and on Pony the assertion is what binds. Text alone does not hold
  a count. This is a defect class of its own: independent of pose and wardrobe, so fixing those
  will not fix it.
- **A failure that clusters on one checkpoint is not proof of a checkpoint property.** Two-woman
  renders clustered on a single checkpoint looked like a model propensity; the actual cause was the
  missing positive prefix, which the cluster could not have distinguished. Rule out the cheap text
  lever before attributing a defect to a checkpoint.
- **What is deliberately ABSENT from the negative is also a decision.** `naked` / `nude` /
  `topless` are intentionally not in it: they suppress the bare shoulders, back and legs the look is
  built on, while the rear-exposure problem was a *framing* failure (rear camera + absent clothing)
  already addressed by cover wording and pose. Do not "harden" the negative by adding them.
- **The pose the base render picks is a FACE-PASS quality lever.** A scene that asks for an
  over-the-shoulder or from-behind angle hands the face inpaint a small, oblique, partly
  occluded crop to re-render, and the face comes back weaker (founder, on `kitchen-apron`:
  *"that gives the face inpainter some trouble - not a blocker generally"*). The inpaint prompt
  cannot repair a bad crop, so pose belongs to scene design, not to the face prompt. A frontal
  or three-quarter-front pose is the cheap fix, and a different seed alone will not change a
  pose the text explicitly requests.
- **Rear framing is an EXPOSURE risk, not a pose taboo.** Founder correction: from-behind is
  *"mainly risky if she's not wearing anything. If you let her wear a tight tshirt and jeans,
  from behind is a great photo."* So the risk is the **combination** of rear framing and absent
  clothing, not the camera angle by itself. Measured consequence of getting that wrong: a
  front-only apron + bare back + from-behind camera produced naked-behind renders that
  invalidated an experiment (E2). With real clothing (t-shirt + jeans) rear framing is both
  available and desirable. Treating this as a one-variable pose rule is what produced a
  two-variable problem.
- **The face pass still prefers frontal, independently of exposure.** A from-behind or
  over-the-shoulder crop hands the face inpaint a small, oblique, partly occluded region, so
  rear-framed scenes trade face quality. Choose rear framing knowingly.
- **The hand pass is an ARM pass too -- they are not separate levers.** The hand inpaint text is
  `"Young female arm and hand"` and its scheduler denoise governs the whole region, so raising it
  to improve hands also re-renders the arms. Expect arm artifacts to appear when you strengthen the
  hand pass, and do not chase them as an independent defect.
- **An empty CLIPSeg mask hard-crashes the graph -- and it is the HAND mask, not the head.** The
  crashing node's mask comes from the *hand* CLIPSeg branch (`prompt: hand`), so "lower the head
  threshold" sends you to a knob that cannot fix it. `Bounded Image Crop with Mask` derives its bounds
  from `torch.where(rows)[0][[0, -1]]` with **no empty guard**, so an empty mask raises
  `IndexError: index is out of bounds for dimension with size 0` (`was-ns/WAS_Node_Suite.py`). It is
  **deterministic per composition, not per checkpoint** -- the same checkpoint renders fine at another
  seed, so do not condemn the model. Lowering the threshold only helps when a hand is present but
  scores under it; a hand genuinely out of frame yields an empty mask either way, so the durable fix is
  a non-empty guard on the crop step. See **The inpaint composite** below for the whole chain.
- **A scene file must contain ONLY prompt text -- the pipeline sends the raw file, comments and
  all.** Measured: design notes appended to a scene file inside an HTML comment were sent to the
  model verbatim (sweep reported `prompt[2240 chars]` against 1051 chars of real scene text), and
  the model rendered the notes -- the founder saw *"a bedroom on her left, and a kitchen on her
  right"* because the note literally said *"setting changes kitchen -> bedroom"*. Keep notes in a
  sibling file (`docs/scene-notes-<name>.md`), and make the reader strip `<!-- -->` blocks so
  this cannot recur.
- *Retracted:* an earlier claim in this file that a *cream linen apron* "carries a kitchen
  prior" and drags a kitchen into a bedroom scene. The contamination was self-inflicted note
  text leaking into the prompt. The garment-prior theory was never tested and is withdrawn --
  do not act on it.

## The inpaint composite: a chain of tuned NUMBERS, not laws

Face and hand passes have the same shape, and every value in it was set empirically against the prompts
and segmentation models of the time. **They are not laws.** The founder, 2026-10-18: *"'hands' used to
be hands only. Now they seem to cover arms and hands. That was the reason for different paddings at the
time. But these are not laws set in stone. They were empirically conceived numbers that worked best with
the prompts at the time. detection/bbox/segmentation models have been changed since."* So when a symptom
smells like staleness, **re-derive the number against the mask you have now** rather than defending it.

The chain, per pass (head = 16 → 45 → crop 10/11 → blend 20; hand = 24 → 29 → crop 30/64 → blend 36):

```
CLIPSeg prompt (threshold) -> GrowMaskWithBlur (expand, blur_radius)
  -> Bounded Image Crop with Mask (padding) -> SetLatentNoiseMask -> Sampler (denoise)
    -> Bounded Image Blend (feathering, blend_factor)
```

What the nodes actually do (`custom_nodes/was-ns/WAS_Node_Suite.py`):

- **crop padding** — `WAS_Bounded_Image_Crop_With_Mask` takes the **mask bounding box** and adds padding
  (clamped to the image). It is *context*: how much surrounding image the sampler sees and gets
  composited back.
- **feathering** — `WAS_Bounded_Image_Blend` builds a white core inset by `feathering` per edge, adds a
  `feathering`-wide zero border, then Gaussian-blurs with radius `feathering`. Net: an alpha ramp of
  roughly `feathering`→`2×feathering` px measured **inward from the crop edge** — it does **not** scale
  with crop size. Then `Image.composite(src, tgt, mask)`, i.e. alpha 255 → source (the inpaint),
  0 → target (the original).
- **blend_factor** — scales that alpha. Declared `min 0.0, max 1.0`, so **1.0 is the maximum** and the
  only available direction makes the target show through *more*. **Not a fix knob.**

**The rule that falls out — and its correction.** The crop is taken over the **grown** mask's bbox plus the
padding, so the margin between the crop edge and the subject is **`expand` + `padding`**, not padding
alone. The ramp must live inside *that*. Initial statement of the rule here ignored the mask expand and was
wrong; corrected: **effective margin = mask `expand` + crop `padding` ≳ 2× `feathering`.**

Measured in the v2 graph — face: padding 85.43 + expand 20 = 105.4 vs feathering 10, comfortable. Hand:
padding 9.75 + expand 20 ≈ **29.75** vs the ~20 px ramp, i.e. **already adequate** — the ramp lands in the
grown margin, which is mostly background around the hand rather than the hand itself.

**And measuring it settled the question: the ramp is NOT the dominant term — magnification is.** E4 raised
the hand padding 9.75 → 48 and the **baseline won the hands axis in every pair where a hands opinion was
given** (baseline 3, raised 1, two ties; H1 rejected). Because the crop is resized to a fixed 1024 canvas
(`ImageResize+`, `keep proportion`), a bigger crop shrinks the subject's share of that budget: **raising
padding bought context at the cost of magnification, and the detail loss was what showed up.** Do not raise
these paddings on a ramp-placement argument alone.

**The depth knob nobody has touched.** With the canvas fixed at 1024, the only free parameter for how much
detail the inpaint can produce is that target size (nodes 32/68 hand, 80/8 face). It is a live candidate for
finger detail — "Pony's hands are not the greatest" is a detail problem, and this number sets the budget.

**So an optimum exists, bounded from both sides:** the margin rule is a **lower** bound on padding and the
magnification coupling is the **upper** bound. E4 tested the upper side (9.75 → 48) and **the upper bound
bit first** — so do not step padding upward expecting a free win.

**Match the aim to the knob** (the aim is the founder's, the knob is measured):

| aim | knob | nodes |
|---|---|---|
| surroundings, so a seam can continue (hair, limb contours) | crop **padding** (trades against magnification) | 47 face, 66 hand |
| how far beyond the detection it may repaint — **the axis that produced the observed damage** | mask grow `expand` | 45, 29 |
| free invention vs "inspired by the existing position" | **denoise** | 110:109 face, 113 hand |
| **fine detail inside the redraw** (fingers) -- never yet moved | the crop's fixed target size (**1024**) | 32/68 hand, 80/8 face |

**Judge the composite structurally, not aesthetically.** Founder: *"What we don't want is disconnected
limbs (flux just paints in a hand) or a face that looks somewhere else than the head."* Both block a render
outright, so a *prettier* arm carrying a detached hand is worse, not better. Count them yes/no per render
rather than ranking preference — see `references/experiment-harness.md`.

**Derive the defect list from observed failures, not from guesses.** E4 pre-registered exactly two classes
(disconnected limb, face off-head); **both counted zero**, while the two defects that actually appeared — and
that decided the ranking — were neither:

1. **Garment / strap integrity** — the arm inpaint painting over, or ghosting, a clothing edge at the
   shoulder. Seen on the arm with *more* context: more surroundings let flux roam further into the clothing.
2. **Breast / nipple intrusion** — the arm inpaint adding or removing a nipple on the breast.

Both are the same underlying fault: **the hand mask is too broad**, so the inpaint repaints garment and torso
skin it was never asked to touch — the same mechanism as the founder's tattoo observation (*"adding arms to
the inpaintable image only adds risk of damage"*). A pre-written taxonomy is only a hypothesis about what
will break; expect it to be wrong, and replace it with what actually broke.

### When a sweep comes back flat or backwards, question the STAGE, not the value

A well-chosen knob that moves nothing useful is **evidence about the stage, not about the number**. The
hand-padding test did not merely fail to help — the hands came back *worse*, and both defects it surfaced
were "the mask is too broad", which is a different stage entirely. Stop sweeping values in that stage and
widen the search instead.

**Compare against a KNOWN-WORKING sibling config before reasoning from mechanism.** Another persona's
saved workflow that performs well is stronger evidence than any derived mechanism, because it is an
*observed* good configuration rather than a plausible one. Diffing one here produced, for otherwise
identical graph topology:

- its **base is generated in the pose of a real photograph** — an openpose ControlNet at strength 1,
  active for the first ~27% of base steps — while this pipeline generates the base **from text alone**,
  i.e. from the checkpoint's own pose priors;
- and its inpaint path is **otherwise identical**, down to the hand denoise.

That is the mechanism for "Pony's hands are not the greatest": with the pose unconstrained the hands are
*invented* from priors, and the inpaint is then asked to repair an invention. Constrain the pose and the
anatomy is already coherent, so the inpaint only has to *refine*. **A defect can originate upstream of
every knob you have been tuning** — check the base pass before adding another composite knob.

**The inference that does the heavy lifting: if the sibling sits on the side of an axis you measured as
WORSE, exclude that axis.** The sibling ran the hand-crop padding that this pipeline's own test measured as
the losing side — and still does better. One config cannot both outperform and sit on the losing side of
the axis that is supposed to explain it, so padding is excluded; with the rest of the inpaint path already
identical, the whole composite is excluded. Subtraction like this beats adding knobs.

**A whole failure class that traces to one node is worth one experiment.** Every Dynamo/SDPA failure in
this project's failure table traces to the compiled path, and the sibling runs the same architecture
*without* `TorchCompileModel`. Recorded as an **untested hypothesis, not a fix**: it is the first thing to
try for that class, and it is a one-node change. (Also noted there: the sibling already runs
`pony/body_weight_slider_v1` at 0.6, so the body-weight-slider axis has a working precedent and a value
with mileage.)

**Two couplings to respect when changing anything here** — neither is visible from the canvas:

1. The blends are **two instances carrying identical values** (feathering 10, blend_factor 1 in both).
   Editing "the blend process" means editing **two nodes**; touch one and you have manufactured a
   face/hand asymmetry.
2. **The hand mask is computed on the output of the face composite** (node 24's image ← node 19 ←
   node 20). A face-pass edit therefore perturbs the hand pass downstream and **is not a one-axis
   change**. E4 changed only the hand crop, which does not feed the face pass.

**Enforce single-axis edits mechanically.** `scripts/make_variant.py` writes a TYPED variant workflow
(`--expect` asserts the baseline still holds pre-edit; the post-edit leaf diff must equal the `--set` count)
and deletes it + exits non-zero on any mismatch. "One axis per test" is otherwise a promise; this makes it a
fact. See `references/pipeline-safe-clone.md` for the typed-value rule and for the SCOPE assertion to use
when the change is structural (a rewiring or an added node) rather than a single leaf.

**An empty mask hard-crashes the crop — and the guard for it was built but never wired.** `GrowMaskWithBlur`
(KJNodes, `comfyui-kjnodes/nodes/mask_nodes.py:958`) is **innocent**: its dilation is guarded by
`and output.max() > 0` and its blur path is safe on an all-zero mask. The throw is one node downstream, in
WAS `Bounded Image Crop with Mask`, which does `torch.where(rows)[0][[0, -1]]` with **no empty guard**
(`was-ns/WAS_Node_Suite.py:12456`). In the v2 graph the crashing crop is **64, on the HAND mask**
(29 ← 24, prompt `hand`) — **not** the head mask, correcting an earlier note; the hand mask legitimately
comes back empty when no hand is in frame.

The intended fix is **already in the graph and dangling**: `GetMaskSizeAndCount` on the hand mask (node 26)
and head mask (node 46) feed `Int To Number (mtb)` nodes (27, 58) whose outputs go **nowhere**, while two
`LazySwitchKJ` bypasses (node 19 = face, node 23 = hand) sit with `switch` **hardcoded `False`**, plus two
dangling `Constant Number` = 0 nodes (7, 28). The author built `mask count > 0 ? inpaint : bypass` and never
connected the last comparison.

**But the signal it was wired to cannot work — do NOT simply finish that connection.**
`GetMaskSizeAndCount` (KJNodes — as are `GrowMaskWithBlur` and `LazySwitchKJ`) returns
`("mask", "width", "height", "count")`, and inside, `count = mask.shape[0]` — the **batch size, not the
number of white pixels**. An empty mask still has `shape[0] == 1`, so `count` is always ≥ 1 and a comparison
against 0 can **never** fire. Detect mask *content* (an area / any-pixel-set measure, e.g. a sum or mean over
the mask), never its shape. So this guard is worse than unfinished: it is built on the wrong quantity while
looking complete from the canvas — treat any "count of masks" reading as a batch dimension until the node's
return names say otherwise.

**The verified sensor chain** (every link checked against node source; built by
`scripts/add_mask_guard.py`, which enforces a scope assertion — no pre-existing parameter may change
except the deliberate switch rewires):

```
grown mask (45 head / 29 hand)
  -> MaskToSEGS            Impact Pack. core.mask_to_segs guards with np.nonzero -- `if len(indices[0]) > 0`
                           -- and returns an empty list for an empty mask, so no bbox math touches
                           emptiness. Safe.
  -> ImpactIsNotEmptySEGS  Impact Pack, logics.py:49: `return (segs[1] != [],)` -> BOOLEAN, False when
                           there is nothing to detect.
  -> LazySwitchKJ.switch   LAZY -- the unselected branch is never executed, so choosing the bypass means
                           the crashing crop node never runs at all. Fixes the crash AND skips a wasted
                           pass.
```

**Polarity is the whole guard, and getting it backwards fails in BOTH directions.** `ImpactIsNotEmptySEGS`
is TRUE when content EXISTS, so `switch=True` must select the **inpainted** branch. The v2 graph's switches
were wired the opposite way (`on_true` = pass-through), so `on_true`/`on_false` must be **swapped**. Wired
backwards the guard is worse than absent: a mask that HAS content selects the raw branch and the inpaint is
**silently discarded** — the pass runs, costs the seconds, and nothing lands — while an EMPTY mask selects
the inpaint branch, so the crop consuming it is still required by the execution plan and the crash fires on
exactly the case the guard exists to prevent. Measured on a hand-built guard with both switches inverted:
3 of 6 runs dead with the empty-mask `IndexError`.

**Not being downstream of a switch is NOT a defect — lazy pruning is the protection.** All four
`Bounded Image Crop with Mask` nodes here (10, 11, 30, 64) take their `mask` straight from a
`GrowMaskWithBlur` with no switch on that path, and the guarded graph does not crash. With the correct
polarity an empty mask makes the sensor False, the bypass is selected, and the whole inpaint branch (blends,
crops, samplers) becomes unreachable — ComfyUI never executes the crop, so its unguarded mask path cannot
throw. Reporting "0 of 4 crops guarded" as a coverage gap is therefore a **false alarm**: read the polarity,
not the path. It is also why this crash is intermittent and composition-dependent — it needs a mask that is
empty *while* the branch consuming it is still reachable. `scripts/trace_crops.py <workflow.json>` prints per
crop its mask chain and whether a switch sits on it, plus every switch's `on_true`/`on_false` wiring. Its `switch` is a **widget**: to drive it from a node, convert
the widget to an input first (right-click -> *Convert widget to input*), then link the boolean — which
turns the scalar leaf `…inputs.switch` into a link, an expected diff rather than a scope violation.

`ImpactConditionalBranch` (Impact Pack) is a more self-documenting equivalent with `cond` / `tt_value` /
`ff_value`, and its branch values are declared `{"lazy": True}` too — use it if wiring by hand in the UI.

**Do not hand the founder a node-level wiring task.** He said plainly that he does not know `LazySwitchKJ`, so
a fix whose handover is "finish this connection in the canvas" is not a deliverable. Either implement the
wiring yourself in the versioned workflow file, or — if he must do it — name the node *and* its UI-equivalent
alternative and spell out the click path (right-click the `switch` widget → *Convert widget to input*). Assume
prompt- and output-level edits are his; treat graph surgery as yours, and say which you did.

**Regression test.** Use the *documented* crasher, never a scene picked at random:
`Pornmaster_v2551619` at seed `20261025` produced an empty hand mask 3/3. The baseline must still
reproduce the `IndexError`; the guarded graph must render. A fix verified on a real failing case is
evidence; a fix that only "should work" is not.

Do **not** instead lower the CLIPSeg threshold: that only makes an empty mask less likely, and it cannot
help at all when there genuinely is no hand in frame.

**And do not try to narrow the mask by detection.** The founder spent a day on it: *"I could not easily get
the detection model to bbox only over the hands. adding arms to the inpaintable image only adds risk of
damage (flux seems to have a tendency to add tattoos)."* An over-broad mask is therefore not merely
imprecise — it is **generative risk**, because letting flux repaint skin it was not asked to touch is how
tattoos appear. Treat "added a tattoo" as a defect class alongside exposure and legibility.

## Ranking tooling: which tool for which job

- **`elo-picker` does not show filenames**, so a ranking there is *already* blind to which
  checkpoint or setting produced what. Use it for **bigger rankings** across many assets.
- **Blinded A/B pair sheets are for small controlled paired tests** -- a specific question of
  the form "A or B, matched on everything else", where a sign test over a handful of pairs is
  the analysis. Build them by randomising the A/B assignment per pair and keeping the key back;
  the RAW POOL filenames do leak the checkpoint (`{scene}__{stem}.png`), which is why the
  sheets matter for that use and not for elo-picker.
- Do not build bespoke ranking machinery for a question elo-picker already answers.

## Approved-checkpoint rail

`PipelineCheckpointAllowlist` (packs/job_orchestration) is the single source for which
base models a render may load; `ALLOWED` mirrors `/mnt/nas-ai-models/checkpoints/pony/`.
A blank value resolves to `DEFAULT` (the known-good baseline, so an unpinned run
reproduces the results the founder likes); an unapproved value is **refused** before a
multi-minute model load.

This is **scope, not a taste gate** — quality is measured and ranked by controls
(elo-picker, AuraFace, engagement) and never vetoed here.

To parameterise another setting (LoRA strengths, sampler, resolution) the same way,
tokenise it in the versioned workflow file and add it to `build_variable_map`. Note that
rgthree **Power Lora Loader** keeps its strengths inside a JSON *array* of objects, so a
scalar `{{token}}` cannot reach them — that needs per-entry handling, not the one-line
trick.

Reading that array correctly matters more than it looks:

- Each slot dict carries `on`. A slot with `on:false` has an **inert** strength, so
  reporting strength alone has already produced a confidently wrong "these LoRAs are
  active" answer. Always print `on/off` beside the strength.
- Trigger words live in the loader's companion `.rgthree-info.json` under `trainedWords`.
  A LoRA whose trigger is absent from the prompt is a **dead gene** -- weights loaded with
  nothing to bind them. An **empty** `trainedWords` list is different: that is normal for a
  *slider* LoRA (a strength-only realism knob with no concept), so empty is not dead.
- A LoRA's file name is neither its trigger nor its display name:
  `micro-bikini.safetensors` is "Micro Bra | Goofy Ai - v1.0" and its trigger is `micro bra`.
- When there is **no** companion (or it is unhelpful), read the LoRA's own provenance: a
  safetensors file begins with an 8-byte little-endian header length followed by JSON, and
  its `__metadata__` carries `ss_output_name` and `ss_tag_frequency`. That is how an opaque
  `tg.safetensors` resolved to `thesegirlz`. Ignore `ss_base_model_version` -- ai-toolkit
  stamps `sd_1.5` even on flux LoRAs.
- A concept LoRA whose trigger is absent from the prompt is **unbound, not inert**: it is
  loaded and applies unconditionally, so its concept leaks in with no text lever to switch it
  off. That is strictly worse than a slot with `on:false`, which really does nothing.

## Tools

- `python3 bin/tc_workflow.py <step_id>... [--diff] [--inventory] [--file PATH]` —
  inspect stored workflows: models/LoRAs/weights, sampler, resolution, text inputs,
  placeholder inventory. `--set NODE.FIELD=VAL --export PATH` builds a parameterised
  variant from a stored step.
- `python3 bin/tc_render.py status` — is ComfyUI up, VRAM, queue depth.
- `python3 bin/tc_render.py checkpoints` — probe each approved checkpoint against
  `/object_info/CheckpointLoaderSimple` BEFORE a batch. A checkpoint with no usable VAE
  passes config and fails at **decode**, after the model load.
- `python3 bin/tc_render.py sweep --scene NAME --prompt TEXT|--prompt-file F --out DIR
  --checkpoints all [--seed N]` — render one scene across several checkpoints on **one
  shared seed**, naming files `<scene>__<checkpoint>.png` and writing a `manifest.json`
  (pool-file → checkpoint → seed → sha256). A shared seed is deliberate: seed luck must
  not confound a pool that is ranking something else.
- Renders to a pool folder are **candidate** renders, not scheduled posts: they do not
  create `ComfyuiJob`/`PipelineRun` rows. The DB ledger and the pool manifest are
  separate; join them on sha256.

## Attributing a crash when the ComfyUI port is shared

The card's ComfyUI is shared: the operator's interactive session posts to the same port as a sweep, and both
land in one log. **Never attribute a crash by timestamp proximity — fingerprint the graph.** Three crashes
sitting inside a running experiment's window belonged to the operator's session, not the run; acting on that
misattribution killed a healthy batch mid-flight.

`GET /history` returns every prompt with its graph and status, so identify the submitter from the SHAPE:

- **node count** — a repo workflow has a fixed count (baseline ~73, its guarded variant ~77); a foreign or
  hand-built graph reads a different number;
- **whether the run's save node exists and what its `filename_prefix` is** — a render submitted by
  `tc_render` carries the SaveImage node with the run's prefix, while a foreign graph often has no save node
  at that id and a null prefix;
- **the per-entry `execution_error` message**, so the crashed set is read directly instead of inferred from
  the log tail.

Corroborate with timing before concluding: `Prompt executed in N seconds` on the crashed entry dates its
start, which is how a crash is shown to belong to a prompt that began before the run did. And a long render
wall-clock is not evidence of a crash — queueing behind a foreign prompt inflates it.

## Reading a render report back to a file

The founder reviews renders in **ComfyUI's own output directory**
(`/mnt/fscache/essdee/ComfyUI/output/`), where `SaveImage` writes
`<filename_prefix>_NNNNN_.png`, and he cites those counters plus the **job id**. Those counters
run across every render ever made, so `apron-00008` is *not* the 8th render of the current
batch -- and the pool path is a different path again, named `<scene>__<checkpoint>.png`.

Resolve it, never guess: `GET /history/<prompt_id>` returns the saved filename, and the stored
prompt carries `87.ckpt_name`, `37.noise_seed` and `111.text` -- checkpoint, seed, and which
scene variant produced it. Map every reported id before diagnosing anything.

Budget from the **warm** figure, not a cold start: ~1.3 min per render once models are loaded,
against ~8-9 min for the first render after a model reload (cold `torch.compile`). A 12-render
paired test is ~16 min, not the ~40 min a cold-start extrapolation suggests.

## The GPU gate, and why "it refused to queue" happens

`bin/comfyui_harness.sh status` prints `claim= job= ours= comfyui= owner= pid= cgroup=
started= reserve= holder=`. `Growth::SchedulerGate` fails closed on a ComfyUI that is
**up but unclaimed**, and an operator instance started without `--reserve-vram` reads
`reserve=missing owner=foreign holder=operator` — so a perfectly usable, idle ComfyUI is
treated as unusable and renders appear to refuse to queue into it.

Founder directive: for **candidate / pool** renders, POST straight to the running
ComfyUI (`127.0.0.1:8188`) — do not take a scheduler claim and do not restart the
operator's instance. The claim protocol governs scheduled production renders that must
not double-book the card.

Never write a pid in prose; name the holder with the tokens the harness prints.

## The brain cannot co-reside with the renderer (phase machine)

The brain is the **uncensored** model: `Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf` (22.08 GB) at
`/home/tim/source/activity/textgen-4.9/user_data/models/`. Prefer it over a safety-tuned
model: the founder rejected the previous base as "too skittish", and an agent's own safety
preference must never be promoted into a persona rule.

22.08 GB plus ComfyUI's ~23 GB peak cannot both fit the 24 GB card, so THINK and RENDER are
**structurally** exclusive -- a hardware fact, not a scheduling preference. Any design that
assumes the brain stays resident while a render runs is wrong before it starts. Hence a phase
machine: `THINK -> stop the LLM -> RENDER -> JUDGE`, with each handoff **verified** (read free
VRAM, fail closed) rather than assumed. The founder frames it as a producer pipeline: the
content-generator writes, llama.cpp stops, ComfyUI picks the render request up.

Persona prompt semantics the founder corrected -- do not re-raise these as defects:

- `petite face, small nose` do **not** make the render read underage.
- `Admiring, affectionate, obedient, submissive` is the gaze/head-pose control (see the text
  surface section above), not characterisation.

## Background sweeps

Kill the **whole process tree**, and verify by process state rather than by the fact that you
killed something. A sweep is launcher -> `tc_render.py`, one child per render, so killing the
launcher leaves the per-render child re-parented and still rendering; two sweeps then race and
one writes a stale render into the pool. Kill by pattern (`pkill -f 'tc_rend[e]r.py sweep'` --
the bracket trick stops the pattern matching your own shell), re-check after a few seconds to
catch a child that re-submitted, and read `/queue` to confirm it holds only what you expect.
**The bracket trick is not a style preference — a pattern whose literal text appears in the command
doing the killing matches THAT command too.** A bare `pkill -f 'my_script.py'` kills the shell issuing
it (the tool call returns `exit -15`, which reads like the kill failed) while the real renderer, a
re-parented grandchild, keeps submitting. Use the bracket form, or kill the PID you recorded at launch. ComfyUI's `/interrupt` does not
release a job that is mid-node; `POST /queue {"clear": true}` drops pending jobs only.

Measured: after `/interrupt` + `/queue {"clear":true}` the queue still read
`running=1 pending=0`. Verify `running=0 pending=0` before declaring a stop.

**Pin an absolute interpreter for any background job.** A backgrounded script can resolve a
DIFFERENT `python3` than the foreground shell does, so a dependency that imports fine when
you probe it can be missing when the job actually runs (`ModuleNotFoundError: PIL` on a box
where the foreground `python3` had PIL 12.3.0). `which -a python3` on this machine returns
five interpreters, including a Hermes-managed venv first and a Homebrew 3.15 that lacks the
package. Invoke background jobs with a full path (`/usr/bin/python3`) rather than `python3`.

Keep optional third-party imports (Pillow, for composite sheets) at the module **top level**,
not lazily inside the function that needs them. A top-level import aborts the run *before* the
first render, so a missing package costs nothing; moving it down converts a free, immediate
failure into 40 minutes of renders followed by a crash on the last step.

**Never edit a workflow or prompt file while a sweep is live** -- the renderer re-reads the
file on every render, so the first renders use the old text and the rest the new, and the
pool silently becomes a mixed batch. Order is always: kill -> verify no process survives ->
verify the queue is empty -> edit the file -> relaunch. This applies to the scene/prompt
file as much as to the workflow.
