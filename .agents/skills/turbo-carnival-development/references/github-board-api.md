# Cutting tickets onto a GitHub Projects v2 board

Lessons from wiring the turbo-carnival board from a script (2026-10-19). Applies to any script here that
creates issues or moves board items.

## Which API for what — the split is not optional

- **Projects v2 is GraphQL-only.** REST has no v2 endpoint: `GET /orgs/{org}/projects` returns **404**
  (that path is Projects *classic*). Do not hunt for a REST route for the board; there isn't one.
- **Issues, labels and issue listing ARE REST**: `POST /repos/{o}/{r}/issues`,
  `PATCH .../issues/{n}`, `POST|GET .../labels`, `GET .../issues?state=all`.
- REST issue responses carry **`node_id`**, which is exactly what `addProjectV2ItemById` wants. That is
  the handoff: create via REST, place on the board via GraphQL.

## The throttle that actually bites

~50 `gh issue` / `gh project` calls back-to-back trips GitHub's **secondary (burst)** limit. It is
**invisible in `/rate_limit`** — that endpoint read 4,575 remaining while calls were being refused — and
`gh` surfaces it as the misleading **`unknown owner type`**. Signature: everything works, then everything
fails, with no quota movement.

Fixes, in order of value:

1. **Batch the board mutations.** All N `addProjectV2ItemById` calls in ONE aliased mutation document;
   all field assignments in a SECOND. Per-issue `gh project item-add` + `item-edit` costs 3 calls each;
   batching makes the whole board **2 calls regardless of N**.
2. **Back off, don't retry hot**: 20/40/60 s on a throttle string clears it in about a minute.
3. Keep the bulk on REST so the GraphQL budget is spent only on the board.

## Pitfalls that cost real time here

- **`gh api` needs `--input -` to read a body from stdin.** Without it the body is silently dropped and
  GitHub answers `422 For 'links/0/schema', nil is not an object` — which reads like a permissions
  problem and is not. `gh api graphql` worked while `gh api -X POST` did not, purely because of this flag.
- **A failed create must never print as a no-op.** The first version reported `already existed` for issues
  that had failed to create, and nearly shipped as "7 tickets delivered" when zero existed. Print
  `CREATE FAILED` and exit loudly.
- **`GET /repos/{o}/{r}/issues` includes pull requests.** Filter items carrying a `pull_request` key, or
  the "existing titles" check matches PRs.
- **Verify by reading the board back** — a successful create response is not evidence the item is on the
  board with the right fields.
- **Verify through `gh project item-list`, not a hand-built GraphQL query.** A hand-built
  `node(id: …) { ... on ProjectV2 { items { … fieldValues … } } }` string has failed to parse in practice
  (`gh: Expected NAME, actual: (none) at [1, N]`) *after* the writes had already succeeded — a failure in
  the checker, not the change. If the read-back errors, re-verify through a second path before reporting
  either success or failure:
  `gh project item-list <n> --owner <org> --format json` — parse `.items[].status` / `.items[].track` in
  Python. Confirm the item count against what you expected to write.
- Claims are made by **status + label**, so never set `approved` programmatically: that label is the
  product owner's gate, and a script that sets it has removed the gate.
- **`gh project item-list` pages at 30 items by default.** A ticket you just added then reads as *missing*
  and looks like a failed write. Always pass `--limit 200` and check the returned item count before
  concluding anything:
  `gh project item-list 5 --owner pi-216 --limit 200 --format json --jq '.items[] | select(.content.number==<n>)'`
- **`gh project item-list` reports `content.labels` as `[]` even when the issue HAS labels.** Measured
  2026-10-19: a ticket carrying `ticket, agent_working, prd:0006` came back with an empty `labels` array
  (so did tickets with no labels, i.e. the field is useless rather than merely stale). Reading the item
  list alone would have concluded the claim label never landed. Verify labels with
  `gh issue view <n> --json labels`, never from the project item listing.
- **`gh api graphql --input <file>` expects a JSON body, not a raw query document.** A raw GraphQL document in the file gets `400 Problems parsing JSON`. Write `{"query": "…", "variables": {…}}` (measured 2026-10-21: the query was fine; only the envelope was wrong).
- **`gh issue view <n> --json projectItems` is a cheap REST status read-back.** In the installed gh the card comes back as `[{"status":{"name":"In Progress","optionId":"…"},"title":"…"}]` — read `.status.name`, not `.fieldValues` (that key is null and breaks iteration). Use it to verify a Status flip without spending the invisible Projects GraphQL budget.
- **Put a long issue/PR body in a file and pass `--body-file <path>`.** A shell heredoc is what loses the
  body (quoting, and the `--input -` omission above), and it can stall on an interactive approval prompt; a
  body file is inert. Write it with the file tool — in a scratch dir, not the repo — then
  `gh issue create|edit --body-file <path>`.

## Cutting a ticket here (the contract, not a formality)

There is no `publish_prd`; the agent cuts tickets against `docs/PROJECT_PLAN.md`. Follow the section order,
because the worker agents and the plan's linkage check read it positionally:

```
## Goal              one line: the capability, not the task
## Linkage           a fenced block, exact keys:
                     Plan        : docs/PROJECT_PLAN.md#<anchor>
                     PRD         : docs/prd/00NN-….md
                     Track       : core-infrastructure | experiment | day-to-day
                     Role        : script-worker
                     Depends on  : #nn, …      (_ready_ when none)
                     Blocks      : #nn, …      (_nothing_ when none)
                     Serves      : the sentence from the plan this exists to make true
## Scope             what is in, AND what is explicitly not
## Success criteria  checkboxed, each one mechanically checkable
## Red lines         the things a later worker would be tempted to do
```

Then `--label ticket --label prd:00NN`, add the item to project 5, and set **Status** (`Todo`) and
**Track**. Leave it **un-approved**: `approved` is the founder's gate, and an agent that sets it has removed
the gate. Any decision you are not entitled to make goes into the body as an explicit open question **with
your recommendation** — never decided silently to make the ticket look complete.

**Linkage has to agree in both directions.** Do not write `Blocks: #nn` for a ticket whose own header does
not declare a dependency on you — two tickets disagreeing about their own relationship is a defect, not
shorthand. Write `Blocks: _nothing_`, state the relationship in prose, and flag the mismatch; never silently
edit another ticket's header to match your new one.

## Read back ONLY the item you touched — a heavy GraphQL read burns the budget invisibly

Measured 2026-10-20: a single hand-built query pulling `items(first: 100) { fieldValues }` off
project 5 succeeded, and then **every** later GraphQL read failed with
`GraphQL: API rate limit exceeded for user ID …` — including `gh project item-list` — while
`gh api rate_limit` reported graphql **4999/5000 remaining**. So the Projects API penalty is not
visible in the rate endpoint, exactly like the burst throttle above, and it does NOT clear on a
60 s backoff (it survived a 45 s wait, a retry, and several REST writes in between).

- Ask for the one item you need (`--jq 'select(.content.number==<n>)'`), never the whole board
  with every field value, when the write you are verifying is a single item.
- A mutation returning `{"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": …}}}`
  is an **acknowledgment, not a read-back** (house rule). If the verifying read is throttled, say
  so explicitly and re-read later — do not report the field as verified.
- REST is a separate budget: issue/label edits, PR create, and check-run reads kept working
  through the whole GraphQL blackout. Claim a ticket with the LABEL on REST, so at least half
  of the claim is provable while GraphQL is down.
- **`gh project item-list` is STALE right after an add, and will deny a write that succeeded.**
  Measured 2026-10-20 (ticket #19): `addProjectV2ItemById` returned an item id, yet
  `gh project item-list 5 --owner pi-216 --limit 300` still reported the same 60 items and
  OMITTED the new one — twice, ~20 s apart — while a targeted `node(id: <item id>)` query showed
  it present with the right `Status`/`Track` values. Prove an add by reading the item back **by
  its item id**; treat `item-list` as a coarse inventory, not a verifier.
- **A ticket can be absent from the board entirely — check before "claiming" it.** #19 had no
  project item at all (it predated the board wiring), so the label half of the claim landed while
  the status half silently had nothing to flip: `item-list` returning `[]` was the truth, not a
  throttle. Validate the list read against a known ticket (`--jq '[.items[] | select(.content.number==<known>)]'`)
  before concluding anything from an empty result, then `addProjectV2ItemById` first.

## Reading an item's single-select field values (Status / Track) by issue number

`projectV2` exposes no `item(id:)` field (only `items` / `template`) and there is no `projectV2Item(id:)`
on the Query root — both fail to parse. The reliable read is to **enumerate the items list and filter
by content number**, pulling each item's field values with per-member fragments. Both `fieldValues` and
`fields` are **unions** — selecting `optionId` / `id` bare fails to parse; you must land on the member:

```graphql
{ organization(login:"pi-216") { projectV2(number:5) {
  items(first:100) { nodes {
    content { ... on Issue { number } }
    fieldValues(first:10) { nodes {
      ... on ProjectV2ItemFieldSingleSelectValue {
        optionId
        field { ... on ProjectV2SingleSelectField { name options { name id } } }
      }
    } }
  } }
} } }
```

Map each `optionId` through its own `field.options` (`{name,id}`) to get the label. To read the
Status/Track option ids (needed for a write), query the board's `fields` the same way —
`fields(first:20) { nodes { ... on ProjectV2SingleSelectField { id name options { name id } } } }`.
Keep the `first:` count to what you need; a full-board `fieldValues` read is the heavy query that
burns the invisible Projects budget (see above).

**The Status field has exactly three options here — `Todo` / `In Progress` / `Done`.** There is NO
"needs review" board state. The `agent_needs_review` / `agent_blocked` / `agent_working` states are
**issue labels, not board Status values**: flip the label on REST
(`gh issue edit <n> --add-label agent_needs_review`), keep the board at `In Progress`, and move it to
`Done` only at merge. Do not hunt for a non-existent Status option — the "needs review" step lives on
the issue's labels.

The matching write: `updateProjectV2ItemFieldValue` with
`value: { singleSelectOptionId: <option id from the field's options> }` — `value` is an
INPUT_OBJECT (`text`, `number`, `date`, `singleSelectOptionId`, `multiSelectOptionIds`,
`iterationId`); the single-select member is `singleSelectOptionId` holding the option id as a
**plain string**. Both `singleSelect: {optionId}` and `singleSelect: "…"` fail
(`Field is not defined on ProjectV2FieldValue`). Pass the mutation + variables via
`gh api graphql --input <file>` with `"value": {"singleSelectOptionId": "<id>"}` in the
variables object — `--input @/path` does NOT expand the `@` (it looks for a file literally
named `@/path`). The working
single-quoted shell form of the mutation is in `references/harness-conformance-and-gherkin-rule.md`;
read the field value back afterwards (a successful mutation payload is an acknowledgment, not a
read-back).

## Claiming and completing — the board half

- **Claim:** the REST label first (`gh issue edit <n> --add-label agent_working` — provable even
  in a GraphQL blackout), then flip Status to `In Progress`.
- **Complete at merge:** remove `agent_working`, and ensure Status is `Done`. The observed
  clean close (measured #103/#108, 2026-10-21) ends with exactly `ticket, prd:NNNN` — the
  claim removes `approved` (REST `--remove-label approved --add-label agent_working`) and the
  close removes `agent_working`, so neither transient label survives.
- **Closing the issue can flip the item to Done on its own.** Measured: a squash-merge
  auto-closed the issue via `Closes #N` in the PR body, and the item then read back `Status=Done`
  with no Done mutation ever run. Read Status back first and mutate only if it is not Done.
- **A later PR that references a closed ticket reverts its board Status off `Done`.** This is the
  inverse of the bullet above, from the same automation. Measured 2026-10-21 (ticket #48): the
  squash-merge auto-closed the issue and `github-project-automation[bot]` set Status `Done`
  (21:11:03Z); a follow-up one-cell `plan:index` PR (#141) whose body referenced `#48` then flipped
  the item back to `In Progress` (21:13:46Z) — the automation re-reads the issue when a PR touches
  it. So a `Done` that was correct at merge can silently revert, and any board-status read
  (e.g. `plan:check`) will then report drift that your code did not cause. After merging any PR
  whose body references an already-closed ticket, re-read that item's Status (`gh issue view <n>
  --json projectItems`, or a targeted `fieldValues` read by item id) and, if it reads
  `In Progress`, re-set it to `Done` via `updateProjectV2ItemFieldValue` and read it back. Expect
  possible re-reverts if the closed ticket is referenced again by future PRs.
- **Do not trust saved option ids — verify against the board before mutating.**
  `config/autonomous/pipeline.yml` records the board's single-select option ids, and they can be
  stale per-option: a stale Done id fails with `The single select option Id does not belong to
  the field` while the current ids in the same file still work. Query the field's
  `options { name id }` (above) for the ids you will use.
- **GraphQL mutations are all-or-nothing, and the output selection is part of the document.** A
  bad output field (e.g. `projectV2Item { status { name } }` — `status` is not a field on
  ProjectV2Item) aborts the whole mutation, so nothing is applied even though the input was
  right. Select only `{ projectV2Item { id } }` and verify the write with a separate read.
