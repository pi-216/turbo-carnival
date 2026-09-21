## ADDED Requirements

### Requirement: Synthetic Marker at Creation

Every render SHALL record its synthetic origin in the attribution spine at creation, alongside
`base_model`, `seed` and `prompt_hash`. Provenance MUST be tracked at creation, because
provenance that was never tracked cannot be disclosed later.

#### Scenario: Render completes
- **WHEN** a render completes for a persona
- **THEN** the resulting Photo records its synthetic origin together with the attribution spine values in the same write

#### Scenario: Pre-existing corpus
- **WHEN** a Photo predates this capability
- **THEN** it is backfilled as synthetic with an unmarked-provenance flag, and is never silently defaulted to human origin

### Requirement: Machine-Readable Provenance in the Asset

A published asset SHALL carry machine-readable provenance identifying its synthetic origin, so
the signal travels with the file and survives re-upload. The bytes served to the platform are
what matter, not a local annotation.

#### Scenario: Asset served to the platform
- **WHEN** an asset is published
- **THEN** the served bytes carry `digitalSourceType=trainedAlgorithmicMedia` (XMP/IPTC, or C2PA when a signer is available)

#### Scenario: Marking is impossible
- **WHEN** provenance cannot be embedded in an asset
- **THEN** the asset is not published and the reason is recorded on the post

### Requirement: Fail-Closed Publish Gate

The publish path SHALL refuse to publish content whose synthetic marker is absent, consistent
with the existing NSFW and realism gates, which fail closed.

#### Scenario: Unmarked content
- **WHEN** a post is submitted for publishing and its photo carries no synthetic marker
- **THEN** no Instagram media container is created and the post records the blocking reason

#### Scenario: Marked content
- **WHEN** a post's photo carries the marker
- **THEN** publishing proceeds with unchanged behaviour

### Requirement: Viewer-Facing Disclosure

Published synthetic content SHALL disclose its synthetic origin to the viewer.

#### Scenario: Post published
- **WHEN** a synthetic post is published
- **THEN** the viewer can see that the content is synthetic, via the platform's own label where the platform applies one, and otherwise via explicit caption disclosure

#### Scenario: Preview before publishing
- **WHEN** a post is previewed before publishing
- **THEN** the preview indicates that the content is synthetic