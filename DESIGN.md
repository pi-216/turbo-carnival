# DESIGN.md — turbo-carnival

> **Status:** CURRENT — the UI design-system home.
>
> **Provenance** — created 2026-10-21 for issue #82 (PRD 0006 F4). It is the home for the app's
> **UI** design system (the admin/harness interface, not the persona's visual style). It absorbs the
> pre-rebuild design docs — the root `DESIGN_SYSTEM.md`, `docs/view_components.md`, `docs/nav.md`
> and `docs/design-system/` (now archived under `docs/archive/`).
>
> The **system architecture** is in `ARCHITECTURE.md`; **operations** in `OPS.md`; the behavioral
> and data **contracts** in `CONTRACTS.md`. When the component inventory below disagrees with
> `app/components/`, the code wins — the component list here is a summary to reconcile.

## What this file owns (one truth per topic)

| Topic | Home |
|---|---|
| The UI stack: Tailwind v4, ViewComponent, Hotwire | **this file** |
| Design tokens (Tailwind v4 CSS-first config) | **this file** |
| The component library (the real inventory) | **this file** |
| Navigation architecture | **this file** |
| The lookbook + preview/testing convention | **this file** |
| The persona's *visual* style (rendering prompts, wardrobe, scene) | `docs/baseline-config.md` + `docs/scene-notes-bedroom-front.md` |

## The UI stack

| Layer | Technology |
|---|---|
| Styling | **Tailwind CSS v4** (CSS-first configuration; tokens as CSS custom properties) |
| Components | **ViewComponent** (Ruby objects + ERB templates, unit-testable, ~10× faster than partials) |
| Interactivity | **Hotwire** (Turbo) |
| Framework | Rails 8 |

> Tailwind v4 is the only sanctioned styling path — avoid custom CSS files where possible. The
> pre-rebuild guides referenced an OpenSpec-driven design-system change; OpenSpec was dropped
> (2026-10-19) and those documents are archived.

## Design tokens

Tailwind v4 is configured **CSS-first**: design tokens live as CSS custom properties in the app's
Tailwind entry, not in a JS config. New tokens are added to the CSS layer and consumed through
Tailwind utilities. (If a token file has drifted from what is rendered, the CSS is authoritative.)

## The component library

Components live in `app/components/`, each a Ruby class + an `.html.erb` template, extending
`ApplicationComponent`. **Every component must have a corresponding preview** in
`spec/components/previews/` so it can be developed and tested visually.

Current inventory (reconcile against `app/components/`):

| Component | Role |
|---|---|
| `ApplicationComponent` / `base/` | The base class for all components. |
| `ButtonComponent` | A typed action button (the workhorse control). |
| `CardComponent` | A container/surface. |
| `ComparisonViewComponent` | Side-by-side comparison (render sets / candidates). |
| `ImageDisplayComponent` | Renders an image (photos / renders). |
| `VotingCardComponent` | A candidate card for pairwise selection. |
| `catalyst/`, `layout/` | Legacy (Catalyst-era) and layout components. |

**Creating a component:** generate the class + template in `app/components/`, define an explicit
`initialize` keyword-argument contract (this *is* the component's type-safety), add a preview in
`spec/components/previews/`, and a unit spec in `spec/components/`. Prefer composing existing
components over new ones; keep presentation in the ERB and behavior in the class.

> The archived `DESIGN_SYSTEM.md` listed a richer component set (Post Card, Photo Grid, Status Badge,
> …) from the Catalyst-era design system. That set is **not** the current inventory — the list above
> reflects `app/components/` as of this writing. Reconcile this table if the library has grown.

## Navigation architecture

The interface is **persona-scoped**: you select a persona first, then the persona-specific
navigation is revealed.

1. **Select Persona** — `personas#index` / `personas#new`.
2. **Persona Home** — dashboard (scheduled posts, content gaps, recent activity).
3. **Content Pillars** — the pillar list; per pillar: overview, edit, suggest content.
4. **Posts & Scheduling** — the scheduled-post list (browse photos, create post), suggest-next-post;
   per post: details, suggest caption, delete.
5. **Content Creation Workflow** — content suggestions (edit / use / reject / generate image), gap
   analyses, campaigns.
6. **Runs & AI Workflow** — the run list (scoped to persona/campaign/run); per run: overview,
   complete, the AI workflow steps.

> The archived `nav.md` is the source for this structure. If the routes have moved, the route map
> and the controllers are authoritative; reconcile this list.

## The lookbook

`app/lookbook` is the visual reference for the component library (a browsable catalog of the
components with their variants). Use it as the source of truth for *what the UI should look like*,
alongside the previews.

## The 2026-10 rebuild status

The UI was rebuilt in the 2026-10 window (the pre-rebuild guides carried `UNREVIEWED — predates the
2026-10 rebuild` headers). The current surface is the Tailwind v4 + ViewComponent library above.
Where a page still looks like the old design system, that page is not yet migrated — flag it rather
than treating the old look as the standard.

## Where reality diverges from this file

- **The component inventory** is a summary; `app/components/` is authoritative. The archived
  `DESIGN_SYSTEM.md`'s component set (Catalyst era) is **not** the current library.
- **Design tokens** are Tailwind v4 CSS custom properties; if a stale token file exists elsewhere,
  the CSS entry is the single source.
- **This file covers the app UI only.** The persona's *rendered* look (identity block, wardrobe,
  scene, samplers) is the render-pipeline concern — its truth is in `docs/baseline-config.md` and
  `docs/scene-notes-bedroom-front.md`, not here.
