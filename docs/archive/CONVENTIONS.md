# Conventions

> **Status:** UNREVIEWED — predates the 2026-10 rebuild; house conventions now come from the t-chat-style AGENTS.md
*   **Controller Responsibilities:** Controllers focus on auth (using **Pundit**), input validation, calling `GLCommand`, and handling command results.
*   **Avoid Domain Logic in Controllers:** Keep domain logic out of controllers; delegate it to `GLCommand`s or service layers.
    **Use state_machines for state management:** For models with any state transitions, use the `state_machines-activerecord` gem (the modern successor to `acts_as_state_machine`). Status columns should be of type string.
*   **Use `GLCommand` for Business Logic:** Isolate and chain individual steps in business logic flows using the `gl_command` gem (https://github.com/givelively/gl_command).
    *   **Naming:** Command class names must start with a verb (e.g., `SendEmail`, `CreateUser`).
    *   **Encapsulation:** Minimize logic in controllers and workers; move complex logic into Commands.
    *   **Single Responsibility:** Each Command should have a small, single purpose.
    *   **Chaining:** Combine multiple Commands into a chain for complex, multi-step operations.
    *   **Rollback:** Commands can implement a `rollback` method to undo their actions.
    *   **Automatic Rollback on Failure:** If any command within a chain fails during execution, the `rollback` methods of all *previously successfully executed commands in that chain* will be automatically invoked in reverse order. Design commands and their `rollback` methods with this transactional behavior in mind.
*   **Testing Strategy:**
    *   **No Controller Specs:** Do not write controller specs.
    *   **Isolated Unit Tests:** Cover classes, methods, and `GLCommand`s with isolated unit tests (mocking DB/external calls where possible and reasonable, **including rollback logic**).
        **RSpec Matchers:** GLCommand comes with a set of RSpec matchers to make testing your command's interface declarative and simple. See https://github.com/givelively/gl_command?tab=readme-ov-file#rspec-matchers
        **Stubbing Context:** If you need the response from a command (typically because you are stubbing it), use the build_context method to create a context with the desired response. This has the advantage of using the actual Command's requires, allows, and returns methods. See https://github.com/givelively/gl_command?tab=readme-ov-file#testing-glcommands
    *   **Request Specs:** Use request specs primarily to test auth (Pundit) and verify the correct `GLCommand` is called with correct args, asserting the HTTP response
    *   **Limited Integration Specs:** Use a few integration tests (e.g., full-stack request specs hitting the DB) for critical end-to-end business flows only. Integration specs and Request specs should not contain mocks/stubs.
    *   **N+1 Query Prevention:** Implement **N+1 tests** (using `n_plus_one_control`) for relevant data-fetching scenarios.
    *   **FactoryBot:** Use FactoryBot for test data setup, ensuring factories are defined in `spec/factories/` and follow naming conventions (e.g., `user.rb`, `photo.rb`). FactoryBot is not set up for short notation, use FactoryBot.create instead.
*   **Migration Scope:** Migrations must only contain schema changes. Use separate Rake tasks for data backfills/manipulation.
*   **Multi-Phase Column Addition:** Follow the safe multi-phase deployment process (Add Col -> Write Code -> Backfill Task -> Add Constraint -> Read Code -> Drop Old Col) when adding/replacing columns.
*   **For UI elements, utilize reusable ViewComponents located in `app/components`. Refer to the ViewComponent documentation (https://viewcomponent.org/) for best practices. Every component must have a corresponding preview file in `spec/components/previews/` to facilitate development and testing.**
*   **Organize code into domain-specific packs using Packwerk (https://github.com/Shopify/packwerk). New logic should ideally be encapsulated within a new or existing pack located in the `packs/` subfolder. Define clear pack boundaries and dependencies.**
*   **UI Styling:** Use modern **Tailwind CSS v4** for all styling. Avoid custom CSS files where possible.

- The user's pre-commit linting and test command is `bin/rspec --fail-fast && bin/packwerk check && bin/packwerk validate && bin/rubocop --fail-fast`
