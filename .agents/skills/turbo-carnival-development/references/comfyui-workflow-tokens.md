# ComfyUI render path — where workflows live, and the placeholder system

Read-derived (live DB + code). Treat this as a map, not as authority: re-run the
commands at the bottom before depending on any specific node id or token, because the
stored workflow is editable data and drifts.

## A workflow is stored data, not a file

`pipeline_steps.comfy_workflow_json` — a `text` column in Postgres. Five pipelines,
nine steps:

| step | pipeline | name | tokens |
|---|---|---|---|
| 32 | 17 `sarah1a3` | Base Image | `prompt`, `run_name`, `auto_seed` |
| 33 | 17 | Enhance Body | `prompt`, `run_name`, `auto_seed`, `parent_image_path` |
| 34 | 17 | Replace Face | `prompt`, `run_name`, `auto_seed`, `parent_image_path` |
| 35 | 17 | Replace Hands | `run_name`, `auto_seed`, `parent_image_path` |
| 36 | 17 | Upscale | `run_name`, `auto_seed`, `parent_image_path` |
| 37 | 18 `sarah-pony-v1` | Generate | `prompt`, `negative_prompt`, `seed`, `filename_prefix` |
| 38 | 19 `sarah-carnival-v1` | Generate | `prompt`, `negative_prompt`, `filename_prefix` |
| 39 | 20 `turbo-one-step` | Generate One Step | `prompt`, `run_name`, `auto_seed` |
| **40** | **21 `turbo-one-step-clean`** | **Generate One Step** | `prompt`, `run_name`, `auto_seed` |

Step flags that select which variables get populated: `needs_run_prompt`,
`needs_run_variables`, `needs_parent_image_path`, `max_children`. Note `needs_run_prompt`
and `needs_run_variables` are separate switches — a step with the second set and the
first clear still receives `prompt`, via the run-variables branch.

## The production step (40) — only 5 of 75 nodes carry tokens

| node | class_type | title | token → field |
|---|---|---|---|
| 50 | Text Multiline | Text Multiline | `{{prompt}}` → `inputs.text` |
| 111 | Text Multiline | Text Multiline | `{{prompt}}` → `inputs.text` |
| 37 | RandomNoise | RandomNoise | `{{auto_seed}}` → `inputs.noise_seed` |
| 55 | Seed | Seed | `{{auto_seed}}` → `inputs.seed` |
| 21 | SaveImage | "Hands Replced Save Image" | `{{run_name}}` → `inputs.filename_prefix` |

The SaveImage title and several step names are lineage leftovers from the older
multi-step pipeline; do not read them as descriptions of what the node does.

## The substitution chain — three passes across three classes

1. **`BuildJobPayload#replace_template_variables`** — string level, BEFORE `JSON.parse`.
   The map comes from `build_variable_map`: `pipeline_run.variables` + `prompt` (run
   column) + `run_name` (run `name`) + system vars `timestamp`, `timestamp_ms`, `random`
   + `parent_image_path` when a parent candidate exists. Values are escaped with
   `to_json[1..-2]`, then `gsub("{{key}}", …)`.
2. **`PipelinePromptSafety.sanitize_workflow`** — the single choke point that rewrites
   stored instruction text. It runs between substitution and submission, so it sees the
   substituted workflow.
3. **`SubmitJob#apply_job_variables`** — re-serialises the workflow to a JSON string and
   resolves the two runtime tokens:
   `"{{job_id}}"` → the `ComfyuiJob` id;
   `"{{auto_seed}}"` → `pipeline_run.variables["seed"] || 1_000_000`, plus `job.id`
   (deterministic per run, offset per job).
4. **`ComfyuiClient#submit_workflow`** — `POST {base_url}/prompt`, body
   `{prompt: <workflow>}`; the response `prompt_id` is normalised to `job_id`.
   `base_url` = `ENV.fetch("COMFYUI_BASE_URL", "http://localhost:8188")`
   (`config/initializers/comfyui.rb`).

Output folder = `File.join(pipeline_run.target_folder, step_name.parameterize)`.

## Gotchas — each one fails silently

- **Two seeds can collapse into one.** Nodes 37 and 55 each once held a *distinct*
  hardcoded seed; both now carry `{{auto_seed}}`, so they resolve to the SAME value.
  Re-tokenising two seeds to one name destroys any dependence on two independent seeds,
  and the workflow still looks fine. Diff the node values before trusting a workflow as
  "unchanged".
- **Runtime tokens only match the quoted form.** Pass 3 does `gsub('"{{job_id}}"', …)`
  and `gsub('"{{auto_seed}}"', …)` — the token must be a whole JSON string value. Put
  `{{auto_seed}}` inside a longer string and it never substitutes.
- **One token can drive several nodes.** `{{prompt}}` feeds nodes 50 AND 111, so a single
  prompt change moves two inputs.
- **An unsubstituted token raises nothing.** If a run supplies neither a prompt nor
  variables, `{{prompt}}` stays literal in the JSON and ComfyUI receives the text
  `{{prompt}}` as the prompt. Verify substitution from the stored `job_payload`, not from
  the absence of an error.

## Reproduce the inventory

Token inventory per step:

```bash
psql -d turbo_carnival_development -At -c "select pipeline_id||'/'||id||' '||name||' -> '||coalesce((select string_agg(distinct m[1],',') from regexp_matches(comfy_workflow_json,'\{\{([a-zA-Z0-9_]+)\}\}','g') m),'(none)') from pipeline_steps order by pipeline_id,\"order\";"
```

Which *nodes* carry tokens (dump one step, then walk it). Write the temp file to the
profile scratch dir, not the system temp dir:

```bash
psql -d turbo_carnival_development -At -c "select comfy_workflow_json from pipeline_steps where id=40" > "$SCRATCH/step40.json"
python3 - <<'PY'
import json,re,os
wf=json.load(open(os.environ['SCRATCH']+'/step40.json')); tok=re.compile(r'\{\{([a-zA-Z0-9_]+)\}\}')
for nid,node in wf.items():
    if not isinstance(node,dict): continue
    found=[]
    def scan(o,p=''):
        if isinstance(o,str): found.extend(f"{m} @{p or 'value'}" for m in tok.findall(o))
        elif isinstance(o,dict):
            for k,v in o.items(): scan(v,f"{p}.{k}" if p else k)
        elif isinstance(o,list):
            for i,v in enumerate(o): scan(v,f"{p}[{i}]")
    scan(node.get('inputs',{}))
    if found: print(nid, node.get('class_type'), (node.get('_meta') or {}).get('title',''), '; '.join(found))
PY
```
