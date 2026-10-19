# Gherkin behavior specs (BDD)

Executable spec of product intent. Pattern (see the gherkin-bdd-pipeline
Hermes skill — this is a required harness pillar, two-role pipeline):

* `gherkin_specs/<domain>/<slug>.feature` — snake_case files, grouped by
  domain. Feature tag `@PRD-000N`, per-scenario `@DEV-NNNN` lineage tags.
* `gherkin_specs/step_definitions/` — shared step library. Reuse before
  writing new steps; new steps are general-purpose with `{string}`/`{int}`
  params. `factories.rb` holds generic `Given a "<factory>" exists with the
  following:` steps; `user.rb` holds login shortcuts.
* `gherkin_specs/support/` — env.rb (requires cucumber/rails), helpers.
* Every `Given` that sets up records maps 1:1 to a REAL FactoryBot factory —
  never invent names/fields/associations; read `spec/factories/` first.
* One action per scenario (gherkin_lint AvoidScripting); ≤15 steps; logical
  Given→When→Then order; first-person present tense; no CSS/DOM/URLs in
  `.feature` files (those live in step definitions).
