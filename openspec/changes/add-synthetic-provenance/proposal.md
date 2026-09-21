# Change: Mark synthetic content at creation and disclose it on the publish path

## Why

Turbo-carnival publishes photorealistic synthetic imagery (Sarah, `a1.sarah.a1`) to Instagram
with provenance tracked nowhere and disclosure existing nowhere:

- `photos` (`db/schema.rb`) has no `synthetic` / provenance attribute — only `persona_id`,
  `path`, timestamps, `image_candidate_id`, `content_pillar_id`.
- No `c2pa` / `exif` / `iptc` handling exists in `app/`, `lib/`, `packs/` or `bin/`; ComfyUI
  writes the render to `comfyui-output` and the file is served by URL, so the bytes reach Meta
  carrying no signal.
- `packs/scheduling/app/commands/scheduling/commands/send_post_to_instagram.rb` publishes
  `image_url` + `caption` and nothing else.

Meta's July-2026 framework applies its "AI info" label only when its detection identifies
generative tooling or reads C2PA metadata; an unmarked asset carries neither, so the account
presents synthetic imagery as photography. EU AI Act Art. 50 (in force 2 Aug 2026) requires
machine-readable marking. Reported exposure is reach suppression, ad rejection, and FTC/UK
advertising-law risk. Tracked as `ai-content-disclosure-absent` on the ops board.

THESIS pillar 2 (attribution spine) already mandates `base_model` / `seed` / `prompt_hash` /
`quality_metrics` on every render. That spine stops at the database and never reaches the
published asset — this change closes that gap rather than inventing a new policy.

**Founder decision (2026-09-21, the agent as founder per THESIS): disclose.** The alive red
line "never fake engagement, buy followers, or pay for growth" already forbids presenting
synthetic as real to move the growth metric, which is exactly what an unmarked photorealistic
persona does. The thesis user wants to *know a person*, not to be shown photography, so
disclosure costs the thesis little and removes a materially worse risk surface (see the open
`persona-age-read-youthful` item: a youthful-reading synthetic persona with no provenance is a
far graver exposure than a disclosed adult one).

## What Changes

- Every render records its synthetic origin in the attribution spine at creation.
- The published asset embeds machine-readable provenance so the signal travels with the file
  and survives re-upload.
- The publish path becomes fail-closed on a missing mark, consistent with the existing
  NSFW and realism gates.
- Disclosure is surfaced to the viewer (platform label where the platform applies one,
  otherwise explicit caption disclosure).

No rendering behaviour, prompt, persona identity, or posting cadence changes.

## Impact

- Affected specs: `content-provenance` (ADDED). Follow-up deltas for `post-creation`
  (preview/caption surface) are split out deliberately so this change stays small.
- Affected code: `packs/pipeline` (render completion), `packs/scheduling`
  (`SendPostToInstagram`, `Instagram::Client`), `Photo` model + migration, caption generation,
  post preview component.
- Migration is additive and multi-phase per `openspec/project.md`: add column → write code →
  backfill task → constrain. No destructive step.
- Reversibility: dropping the marker restores prior behaviour; nothing about the asset
  pipeline is locked behind the mark except the publish gate, which is intentional.