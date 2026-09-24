## ADDED Requirements

### Requirement: Motion Asset Construction

The harness SHALL be able to compose a short vertical motion clip from renders it has already
produced, without a second rendering pipeline and without human authoring. The clip MUST satisfy
Instagram's Reels geometry (9:16, 1080x1920, H.264, yuv420p, MP4) so that a publishing attempt
is not rejected on the asset's format.

#### Scenario: Clip composed from renders
- **WHEN** two to eight render files are composed into a reel
- **THEN** the result is a 1080x1920 H.264/yuv420p MP4 whose duration matches the per-photo
  duration and crossfade arithmetic of its inputs

#### Scenario: A 4:5 render is fitted, not cropped
- **WHEN** a render's aspect ratio is narrower than 9:16
- **THEN** it is fitted whole onto the 1080x1920 frame over a blurred fill, and no part of the
  subject is cropped away

#### Scenario: Composition is impossible
- **WHEN** fewer than two readable photos are supplied, or ffmpeg is unavailable
- **THEN** the builder raises with the reason and produces no partial asset, because a partial
  asset silently becomes a lost publishing slot

### Requirement: Mark on Motion Assets

A motion asset SHALL carry the machine-readable synthetic mark in its own bytes before it is
publishable, exactly as a still does (THESIS pillar 2). The mark MUST be verifiable by reading
the asset back, not by trusting the writer's return value.

#### Scenario: Marked clip
- **WHEN** a reel is built
- **THEN** its container metadata declares
  `Iptc4xmpExt:DigitalSourceType = trainedAlgorithmicMedia`, readable from the file

### Requirement: Reels Publish Path

Publishing SHALL support a Reels video container on the same account and API as stills, sharing
the caption, the AI self-disclosure and its fallback, the single-use container, and the publish
retry. The still path's own request MUST NOT change as a result.

#### Scenario: Reel published
- **WHEN** a reel asset is submitted for publishing
- **THEN** a `media_type=REELS` container is created from `video_url`, its readiness is polled
  on a video-length budget, and a successful publish returns the post id

#### Scenario: Still published
- **WHEN** a still is submitted for publishing
- **THEN** the container request carries no `media_type` and no `video_url`, byte-for-byte as
  before Reels existed

#### Scenario: Container fails processing
- **WHEN** the video container reports `status_code=ERROR`
- **THEN** publishing fails with that reason rather than publishing nothing silently

### Requirement: Discovery Is the Arm's Metric

A distribution arm that exists to create non-follower reach SHALL be evaluated on measured
non-follower reach, never on engagement. An account with no discovery cannot produce an
engagement signal, so reading engagement there re-derives a structurally flat zero.

#### Scenario: Arm measured
- **WHEN** the arm's effect is assessed
- **THEN** the read is `growth_snapshots.non_follower_reach`, where any value greater than zero
  is the first evidence that discovery happened

#### Scenario: Reach attribution unavailable
- **WHEN** the platform answers without a follow_type breakdown
- **THEN** the value stays UNKNOWN rather than being recorded as a measured zero, so a response
  shape change cannot manufacture a "no discovery" verdict

### Requirement: Arm Sequencing Against a Pre-Registered Read

A new publishing format SHALL NOT be introduced into a window that a pre-registered experiment
read is measuring, because the cohort definition counts published posts of the existing kind and
a new format inside that window is an uncontrolled variable.

#### Scenario: Pre-registered read pending
- **WHEN** a pre-registered gate read is pending for a defined window
- **THEN** the arm's machinery may be built and tested but is not armed on the publishing rail
  until after that read, and the sequencing reason is recorded before any publish