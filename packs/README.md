# Bounded contexts (packs)

Each directory under `packs/` is a bounded context: models, commands,
controllers, views, and specs that belong together, with explicit
dependencies between packs.

Create a pack:

1. `mkdir -p packs/<context>/app/{models,commands,controllers,views}`
2. `mkdir -p packs/<context>/spec`
3. Add `packs/<context>/package.yml`:
   ```yaml
   enforce_dependencies: true
   dependencies:
     - "."
   ```
   (The root package `"."` is always available; declare real cross-pack deps
   and enforce. See the packwerk-bounded-contexts Hermes skill: the #1 trap is
   "green but inert" enforcement — packs-rails railtie must load and
   `packs/*/app` must be on the autoload paths; this template wires the
   autoload in config/application.rb.)
4. Namespace code under `Context::*` (e.g. `Identity::User`).

Rule: new logic belongs in a pack, not the root `app/`. If unclear which
context owns a file, ask — don't default to root.
