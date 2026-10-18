"""Apply the founder's config deltas to turbo-one-step-v2 (idempotent, single writer).

D1. node 41 lora_3 (flux/tg.safetensors) -> on=False
    `tg` is `thesegirlz`; its trigger word appears in no prompt anywhere, so it was
    applying UNBOUND at strength 0.6 on the face pass. Founder: "drop thesegirlz".

D2. node 113 BasicScheduler.denoise 0.6 -> 0.68
    Node 113 feeds node 85 SamplerCustomAdvanced, which is the HAND inpaint pass
    (guider 40 <- node 38 <- node 86 "Young female arm and hand").
    Founder: "Make sure that the hand-inpainter has at least a strength of 0.68."

    The FACE inpaint is a SEPARATE scheduler, node 110:109, at denoise 0.66, and is
    deliberately NOT touched here. Note the consequence: at 0.68 the hand pass is now
    stronger than the face pass (0.68 > 0.66), which it was not before (0.60 < 0.66).

Both edits are written in ONE read-modify-write so no delta can be clobbered.
"""
import json
import pathlib

P = pathlib.Path("comfy_workflows/turbo_one_step_v2/step1_generate.json")
wf = json.loads(P.read_text())
changed = []

# --- D1: drop thesegirlz ------------------------------------------------------
slot = wf["41"]["inputs"]["lora_3"]
assert "tg.safetensors" in str(slot.get("lora")), slot
if slot.get("on"):
    slot["on"] = False
    changed.append("node 41 lora_3 (flux/tg.safetensors = thesegirlz) -> on=False")

# --- D2: hand inpainter strength ---------------------------------------------
assert wf["113"]["class_type"] == "BasicScheduler", wf["113"]
sch = wf["113"]["inputs"]
cur = sch.get("denoise")
if cur is None or float(cur) < 0.68:
    sch["denoise"] = 0.68
    changed.append("node 113 (hand inpaint) denoise %s -> 0.68" % cur)
elif float(cur) == 0.68:
    changed.append("node 113 already 0.68 (no-op)")
else:
    changed.append("node 113 already %s (>= 0.68, left alone)" % cur)

if changed:
    P.write_text(json.dumps(wf, indent=2, sort_keys=True) + "\n")

# --- verify from disk --------------------------------------------------------
wf = json.loads(P.read_text())
print("changes:")
for c in changed or ["none"]:
    print("   " + c)
print()
print("flux stack (node 41):")
for k, v in sorted(wf["41"]["inputs"].items()):
    if isinstance(v, dict) and "lora" in v:
        print("   %-8s on=%-5s strength=%-5s %s" % (k, v.get("on"), v.get("strength"), v.get("lora")))
print()
print("inpaint strengths (denoise):")
print("   face  node 110:109  denoise=%-5s steps=%s  -> node 84" % (wf["110:109"]["inputs"].get("denoise"), wf["110:109"]["inputs"].get("steps")))
print("   hand  node 113      denoise=%-5s steps=%s  -> node 85" % (wf["113"]["inputs"].get("denoise"), wf["113"]["inputs"].get("steps")))
print("   base  node 96       denoise=%-5s steps=%s" % (wf["96"]["inputs"].get("denoise"), wf["96"]["inputs"].get("steps")))
