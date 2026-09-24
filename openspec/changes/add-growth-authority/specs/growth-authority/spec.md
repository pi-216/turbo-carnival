# Growth Authority — decision gate for the growth harness

The authority layer turns the harness's advisory loop (measure → log → repeat) into a
*gated* loop with pre-registered, falsifiable verdicts. Thresholds are named constants;
the weekly review is the ruling body, and every verdict it produces is persisted and
reversible.

## ADDED Requirements

### Requirement: Pre-registered trajectory gate
The system SHALL classify each weekly review into exactly one authoritative verdict using
pre-registered thresholds on `traj_ratio` (measured/required daily growth), and SHALL
persist the verdict, the ratio, and the consecutive-review counter.

Thresholds (named constants):
- `GO`: `traj_ratio >= 1.0`
- `BEHIND`: `0.5 <= traj_ratio < 1.0`
- `PIVOT`: `traj_ratio < 0.5`
- `KILL`: `traj_ratio < 0.2`

#### Scenario: Hopeless trajectory converges on PIVOT
- **WHEN** `traj_ratio < 0.5` is observed on 2 consecutive weekly reviews
- **THEN** the system SHALL mandate a structural change (see "Pivot mandate") and record a
  `pivot_applied` decision, rather than re-logging `behind`.

#### Scenario: Sustained failure converges on KILL
- **WHEN** `traj_ratio < 0.2` on 4 consecutive weekly reviews, OR 2 consecutive pivots fail
  to move the ratio
- **THEN** the system SHALL emit a `goal_unattainable` verdict, halt production, and surface
  the recommendation to the operator.

### Requirement: Escalation-exhaustion is persisted
The system SHALL persist a `strategy_exhausted` Decision whenever every escalation knob
that has a production consumer is at its maximum and the trajectory is still `behind`.
Escalation reaching its ceiling SHALL NOT be a silent no-op, and a knob that no
production path reads SHALL NOT be an escalation rung.

#### Scenario: At max effort, still behind
- **WHEN** an `escalate` review finds `posts_per_day == max_posts_per_day` while
  `traj_ratio < 0.75`
- **THEN** the system SHALL write a `strategy_exhausted` Decision with reason text naming
  the exhausted knob (`posts_per_day`) and the ratio.

#### Scenario: An inert knob is not a rung
- **WHEN** a goal field is written by the strategy loop but read by no production path
  (`hashtag_count`: the tags that reach a post come from `ContentStrategy::HashtagEngine`
  over the pillar/persona strategy, and from `Personas::HashtagStrategy#max_tags`, which
  `PersonaEvolution#enforce_tag_baseline` pins to `TAG_BASELINE`)
- **THEN** the field SHALL NOT appear in the escalation ladder, because ramping it records
  an adjustment that changes nothing while postponing the exhaustion conclusion past the
  point where the last live knob was spent.

### Requirement: Resource-blocked attribution
The system SHALL attribute a `behind`/`pivot` trajectory to resource starvation when the
review window's render-blockage density exceeds a pre-registered threshold, and SHALL
classify it `resource_blocked` instead of a strategy failure.

#### Scenario: GPU walled off for most of the window
- **WHEN** `comfyui_unclaimed` + `cadence_blocked` decisions account for more than
  `RESOURCE_BLOCK_RATIO` (default 0.6) of the review window's hours
- **THEN** the system SHALL record `resource_blocked` and route the escalation to the GPU
  scheduler, not to cadence/persona changes.

### Requirement: Pivot mandate with reusable gates
When a PIVOT verdict is reached, the system SHALL select and apply a structural lever from
a pre-registered set (persona reweight, caption strategy, pipeline/base-model swap, posting
time/shift, feed-vs-Reels), and SHALL pre-register a success gate for that lever, reverting
it at the following weekly review if the gate fails.

#### Scenario: Pivot applies and reverts on gate failure
- **WHEN** a PIVOT applies a pipeline/base-model swap
- **THEN** the swap is recorded with attributable identity (base_model/pipeline id) and a
  numeric gate (e.g. next-review engagement or ratio delta)
- **AND WHEN** the gate fails at the next review
- **THEN** the swap is reverted and a `revert_pivot` decision is recorded.

### Requirement: Goal-unattainable treadmill detection
The system SHALL detect the catch-up treadmill — required daily growth diverging from
measured growth — and treat a pre-registered divergence multiple sustained over review
counts as a `goal_unattainable` condition regardless of raw ratio.

#### Scenario: Required growth outruns any achievable pace
- **WHEN** `required_daily_growth / measured_daily_growth >= UNATTAINABLE_DIVERGENCE`
  (default 10.0) for 3 consecutive weekly reviews
- **THEN** the system SHALL emit `goal_unattainable`, halt production, and recommend
  re-targeting the goal (new `target_followers`/deadline) or retiring it.