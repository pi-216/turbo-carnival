"""Add Sarah's hair to the identity block in the versioned wf, whose absence made
hair a free variable (it varied by seed and checkpoint).

Hair belongs in the IDENTITY block (node 88), not the scene prompt: it is a persona
attribute that must be constant across every scene forever. Putting it in the scene
prompt would mean every future scene has to remember to include it -- which is the
exact class of silent omission that has already cost two batches today.
"""
import json
from pathlib import Path

PATH = Path("comfy_workflows/turbo_one_step_v2/step1_generate.json")

OLD = "sarah1a3, slender, freckles, tiny waist"
NEW = "sarah1a3, slender, freckles, long flowing brunette hair down to her waist, tiny waist"

wf = json.loads(PATH.read_text())
text = wf["88"]["inputs"]["text"]

if NEW in text:
    print("already applied -- nothing to do")
    raise SystemExit(0)

if OLD not in text:
    raise SystemExit(f"expected identity anchor not found in node 88; refusing to guess.\nGot:\n{text}")

wf["88"]["inputs"]["text"] = text.replace(OLD, NEW, 1)

# Same serialisation the exporter uses, so the diff stays one line.
PATH.write_text(json.dumps(wf, indent=2, sort_keys=True) + "\n")

print("node 88 identity line updated:")
for line in wf["88"]["inputs"]["text"].splitlines():
    if "sarah1a3" in line:
        print("   ", line)
