# Strategy v3 — the operating model

> **Status:** CURRENT — the operating model, agreed 2026-10-18

Only rules the *founder* stated are recorded as rules. Anything the
agent proposed is in the clearly-marked section at the bottom and carries no authority until he
accepts it. (Standing rule in this project: an agent may not promote its own preference into a
founder red line.)

## The three blocks

| block | the contract that must hold |
|---|---|
| **1 — infrastructure** | Instagram access live. ComfyUI ownership explicit: use an already-running instance untouched; if *we* launched it, shut it down again; never kill a foreign one. |
| **2 — day-to-day** | Runs unattended and posts. **No human dependency at all.** This is the hard requirement. |
| **3 — experimentation** | Runs in parallel and **must never block Block 2**. Asks the founder only when *it* decides input is required; if the answer doesn't come, it **parks — it does not block.** |

Founder, 2026-10-18:
> *"I am hoping that this can be an 'autonomous' content creator. I am very happy to guide, and I
> am very happy to lend my eyes to the system to help. But I am a tool or consultant in this. not
> the blocker or approver or creator."*

> *"the entire flow/agent/harness needs a desire built in to grow. stagnation is not success."*

## Authority: a risk ladder, not an approval ladder

There is **no universal approval rule**. Founder, 2026-10-18:
> *"no universal answer: If the model thinks the risk is too high, it waits for my input. If it is
> experimenting with new base models and found a way to ensure that the persona has all four limbs
> and exactly one hand: go with it."*

So autonomy scales **inversely with the severity of the downside**:

| class | example | who decides |
|---|---|---|
| 1 — correctness / quality | anatomy: four limbs, exactly one hand | **system acts** |
| 2 — style / format / pillar | new scene type, new LoRA, new base model | **system acts**, measured |
| 3 — explicitness / intensity | swimwear and beyond | **founder ruling** |
| 4 — identity / persona | age read, persona identity | **founder ruling** |

The founder explicitly asked for *"some fear that we get shut down"* to be built in. Enforcement
signals (post removals, warnings, reach suppression) are therefore first-class **negative** metrics,
not incidental log lines.

## Raw-data capture — the substrate for everything

Founder, 2026-10-18:
> *"We must collect and persist as much raw information as possible: models, prompts, prompt parts,
> seeds, time of day posted, day of week posted, all of it. They are all awesome raw data for
> experiments."*

Note **prompt parts**, not the assembled prompt. The workflow builds its text from the identity
block + the scene + the negative, and each has to be a **named, addressable field** — otherwise an
outcome can be attributed only to "the prompt", which is not a thing you can change.

This is what lets evidence accumulate over time, and it is the prerequisite for both halves of
attribution: *what produced this asset*, and *what changed when the metrics moved*.

## Promotion: Block 3 → Block 2

**Automatic, on a pre-registered evidence threshold.** The founder is advisory input, not a gate.
A human-gated promotion would make Block 3 a longer route to the same bottleneck — which is exactly
what Block 3 exists to avoid.

## Block 2's job list (founder's words, 2026-10-18)

1. a nightly job that pulls engagement per asset — **total engagement vs initial / long-tail**
2. a job that knows whether new content is required
3. a job that decides *what* to generate — *ideas, not requirements yet*: avoid repetition? get
   inspired? identify trends?
4. something that files the content to be generated
5. something that picks up generation requests, pushes them into ComfyUI, and **closes the loop**
   (upload to GitHub / local upload / file link / database write)

## Open items

- **brain host** — 4090 vs max395. On this structure it is a Block-2 *internal* concern, not an
  architectural one: the only thing serializing on the 4090 is Block 2's own thinking and rendering.
- Node 64 hard-crashes on an empty mask. **Corrected attribution:** node 64 is the **hand** crop — its mask comes from node 29 ← node 24 (`ApplyCLIPSeg+`, prompt `hand`, threshold 0.4), not `head`. Source-level cause: `WAS_Bounded_Image_Crop_With_Mask.bounded_image_crop_with_mask` does `torch.where(rows)[0][[0, -1]]` with no empty guard, so an empty mask raises `IndexError` at WAS_Node_Suite.py:12456. Unfixed.
- `cyberrealisticPony_v180Coreshift` still fails at node 96 (Dynamo); `--disable-comfy-compiler` untested.
- arm vs hand denoise: node 86 covers *"Young female arm and hand"*, so 0.68 re-renders arm too.

---

## Proposed by the agent — awaiting the founder's nod (no authority yet)

1. **A field that is never varied cannot teach anything.** Time-of-day and weekday are exactly such
   fields while posting is cron-pinned to `:00`. The capture is right, but those columns are
   constants until the poster deliberately *varies* them as an experimental factor. Either make them
   factors, or record them as currently uninformative so nobody later reads a trend into a constant.
2. **Part-level capture doubles as the anti-repetition instrument.** The measured content failure
   was ~18 distinct scene prompts re-rendered 15–22× each. With prompt parts stored separately,
   "distinct scenes per window" becomes a query instead of something discovered in the output.
3. **Graduated autonomy needs a *cumulative* risk ledger.** The dangerous path is not one risky
   decision, it is a staircase of individually-small ones; per-decision gating cannot see it. Directly
   relevant: the 36 posts "removed by Instagram" were the founder's **own** removals — so unless
   operator removals are tagged distinctly from platform enforcement, the enforcement signal is
   contaminated and the risk ledger is wrong.
4. **A growth drive needs a leverage-ranked action space, or it degenerates into busywork.** The
   measured ranking is stark: 344 static posts produced **zero non-follower reach ever**, while the
   single reel produced non-follower reach *and* profile views the next day. So "stagnation is not
   success" should first reallocate effort to **format**, not re-tune captions and hashtags — those
   were measured inert on a surface with no discovery step.
