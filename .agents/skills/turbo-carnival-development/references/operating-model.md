# Operating model — the founder's standing rules

Authoritative record: **`AGENTS.md`** (the authority ladder, the one hard gate) plus
**`docs/PROJECT_PLAN.md` §2–3** (the workstreams, the ordering, the standing obligations). The
operating model previously lived in `docs/strategy-v3.md`, which was **deleted** — do not look for it
or cite it. `docs/strategy-v2.md` §1–7 holds the venue and measurement findings underneath it, and
promotion is defined in PRD 0004.

**Which document is authoritative: read `docs/README.md` first.** It is the documentation index — a
"one truth per topic" table plus a full inventory — and every document in the repo carries a status line
under its title (`CURRENT` / `REFERENCE` / `UNREVIEWED` / `HISTORICAL` / `SUPERSEDED`). Read the status
before trusting a document; `UNREVIEWED` means confirm it first (every pre-rebuild doc sits in that
bucket).

The strategy docs divide cleanly and **none is superseded wholesale** — the SKILL.md one-liner that says
otherwise is wrong, and skipping v2 loses the research that exists nowhere else:

| question | document |
|---|---|
| how the project operates (authority, gates) | `AGENTS.md` |
| workstreams, ordering, standing obligations | `docs/PROJECT_PLAN.md` §2–3 |
| why the strategy is what it is — distribution diagnosis, the two-venue design, platform findings | `docs/strategy-v2.md` **§1–7** |
| what work exists, in what order, and why | `docs/PROJECT_PLAN.md` |
| the validated render configuration | `docs/baseline-config.md` |
| experiment verdicts | `docs/experiment-backlog.md` |
| how tickets are cut and linked | `docs/PROJECT_PLAN.md` §4 |

Only v2's §8–13 **process** sections are superseded — by `AGENTS.md` and `PROJECT_PLAN.md` §2–3.

**Never add a parallel document.** When how the project works changes, edit the CURRENT document. A `v2`
and a `v3` both describing the operating model is the failure the index exists to undo — and the older
one keeps getting read. If a stamping pass leaves a doc carrying both a fresh status line and its own
stale inline status, resolve it to one statement and delete any claim in it that has since become false
(`strategy-v2.md` still asserted "nothing here is built yet" long after the render rail, the harness and
the board existed).

## Blocks and their dependency rules

The retired Block 1/2/3 language maps onto the plan's workstreams — **Block 1 ≈ W1, Block 2 ≈ W3,
Block 3 ≈ W2** — and the repo now speaks in W-ids. Older docs still say "Block"; translate rather
than treating them as a different model.

- **Block 1 — infrastructure.** Instagram access live; ComfyUI ownership explicit (use an
  already-running instance untouched, shut down one *we* launched, never kill a foreign one).
- **Block 2 — day-to-day.** Must run unattended and post with **no human dependency at all**. This is
  the hard requirement.
- **Block 3 — experimentation.** Must **never block Block 2**. When it wants human input it files a
  ticket and parks; an unanswered ticket is a stall-free state, not a failure.

## Autonomy is a risk ladder, not an approval ladder

There is no universal "ask the founder" rule. Autonomy scales **inversely with the severity of the
downside**:

| class | example | who decides |
|---|---|---|
| correctness / quality | four limbs, exactly one hand, sharpness | **system acts** |
| style / format / pillar | new scene type, new LoRA, new base model, **or the content-pillar set itself** | **system acts**, measured |
| explicitness / intensity | swimwear and beyond | **founder ruling** |
| identity / persona | age read, persona identity | **founder ruling** |

Promotion Block 3 → Block 2 is **automatic on a pre-registered evidence threshold**. The founder is
advisory input — a tool and a pair of eyes — **not the blocker, approver, or creator**. A human-gated
promotion would make Block 3 a longer route to the same bottleneck, which is what Block 3 exists to
avoid.

## The content-pillar set is fair game — and "pillar" means two things

Founder ruling, 2026-10-19: *"The brain or experimenter should know that the existing pillars are fair
game."* The **content-pillar set is class 2** — the system acts, measured — not a founder rail. The brain
(planner / Thinker) and the experimenter (experiment-lane researcher) may **reweight, retire, replace,
rename, split or add** a pillar, and an experiment may target an existing pillar instead of only proposing
a new one. Enforcement is the existing bounded path: `Growth::PersonaEvolution` is the only writer of a
pillar's `weight`/`priority`/`active`, steps one delta within hard caps, and auto-reverts on a failed
pre-registered gate — so "fair game" never means an unrecorded edit.

**Disambiguate "pillar" before acting on any directive that uses the word** — this repo means two
different things by it:

| sense | what it is | where |
|---|---|---|
| **content pillars** | the content mix the harness posts: Fashion & Style, Food & Cooking, Wellness & Self-Care, Lifestyle & Daily Living (plus inactive/seasonal ones) | `ContentPillar` rows, `Growth::PillarPrompt` scene banks, `Growth::NightlyPlanner` |
| **founder rails** | five *locked* rails: identity anchor, attribution spine, safety gates, decision ledger, reflection | `THESIS.md` "Locked pillars" — and `THESIS.md` is **HISTORICAL**, not truth for anything else |

A directive about "the pillars" is almost always the first sense. The second is locked and includes the
safety gates, so never read "fair game" as reaching it.

Two practical notes from landing that ruling: a pillar's **name is not a schema** — `Growth::PillarPrompt`
resolves a scene bank by name and falls back to a default pool for one it does not know, so a renamed or
newly added pillar renders from the default pool until its bank is added (a variety gap, not a crash); and
the **planner's own system prompt** (`GapAnalysisAi::Suggester`) is the only runtime place the local seat
can be told any of this, because the nightly plan hands it one existing pillar at a time.

## The agent owns the mechanism; the founder owns the eyes

His delegated role is **eyes and rulings, not operation**. When a fix or an experiment depends on a node,
tool, or feature he says he does not know how to use, **implement and verify it yourself** — do not hand
back a how-to and wait. He already delegates experiment design outright ("you decide on the experiment"),
so a proposal that ends with the founder needing to learn a tool has moved work onto the wrong side of the
division. Explain the mechanism only as far as a ruling needs it.

Corollary: when the thing he is being asked about is *visual* — a pose map, a rendered defect, whether one
arm looks better — get the artifact in front of him rather than describing it. And keep node-level detail in
the pipeline references, where the next session will actually look for it.

## Growth drive

*Stagnation is not success*: flat metrics are a signal to act, and the reflex must be ranked by
**measured leverage**. Format first — reels are the only discovery surface (statics measured at zero
non-follower reach ever) — not captions or hashtags, which measured inert.

Enforcement signals (post removals, warnings, reach suppression) are first-class **negative**
metrics, because the account being shut down is the downside the whole risk ladder protects against.

Tag **operator removals distinctly from platform enforcement.** Posts previously recorded as
"removed by Instagram" turned out to be the founder's own manual removals of weak imagery, so an
untagged ledger reads housekeeping as a platform warning and mis-prices the very risk it exists to
measure. A negative signal you cannot attribute is worse than no signal, because it moves the risk
budget on your own tidying up.

## Raw-data capture

Persist per asset: models, prompts, and **prompt parts** — the identity block, the scene, and the
negative as **named addressable fields**, never only the assembled string — plus seeds, sampler
settings, and posting context (hour, weekday).

A field that is never varied cannot teach anything. Mark such a column uninformative rather than
leaving a later session to read a trend into a constant.

## Authority boundary

An agent may **not** promote its own preference into a founder rule or a red line, and must not write
a proposal into the rule body. Attribute every standing directive to who decided it. This project has
already been burned once by an agent-authored safety rule being read as a founder instruction.

## Ticket claims, and who merges

The board is the queue **and** the audit trail; the ticket is the job. A claim is made by flipping the
board Status **and** the lifecycle labels together, and an agent never sets `approved` — that label is
the product owner's gate, and a script that sets it has removed the gate.

**Merging is delegated to the agent** (founder standing instruction: *"You merge"*). Land your own PRs
squash-merged rather than leaving them for a founder merge sweep — a green, mergeable PR with lifecycle
labels still attached is *unfinished work*, not a hand-off. Then close the loop in this order: merge →
verify the issue closed and the card moved to Done → **strip the lifecycle labels** (a shipped ticket
still wearing `agent_working` reads as in-flight) → update the plan row for the item.

Two consequences worth stating: never claim a ticket is complete while its PR is unmerged, and check
the plan's own row before reporting done — a row still reading "spec written" after the work shipped is
drift this repo treats as a defect.
