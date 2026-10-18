"""Apply the founder's text corrections to the turbo-one-step-v2 workflow.

TWO CHANGES
-----------
1. node 88 (identity block): drop `underbooba` / `underboobs`. Those are the
   TRIGGERS for the underboob LoRA, and that LoRA is OFF (`on: false`), so the
   tokens were invoking a concept nothing was supplying -- dead weight in the
   base render's positive conditioning.

2. node 50: replace `{{prompt}}` with a STATIC face-portrait prompt.
   WHY THIS MATTERS: node 50 feeds node 75 -> FluxGuidance -> BasicGuider ->
   SamplerCustomAdvanced (node 84, 35 steps, denoise 0.66). That is the FACE
   INPAINT pass -- it crops to the head mask (node 16, CLIPSeg `head`), re-renders
   the crop, and composites it back. Feeding it the SCENE text renders the scene
   INTO the face crop ("a woman in an apron where the face should be"). The scene
   belongs only in node 111, which is the pony base render.
   Flux1-dev is used for the face and hands passes only (node 86 is the hands
   prompt); the base image is the pony checkpoint.

Idempotent: asserts the expected current state and refuses to guess.
"""
import json
from pathlib import Path

PATH = Path("comfy_workflows/turbo_one_step_v2/step1_generate.json")

FACE_PROMPT = """A close-up, hyper-realistic portrait focused on the face of a white Caucasian young woman. She has an angelic, innocent expression, blushing, featuring big, expressive eyes with a soft, admiring gaze, a small upturned nose, and full, pouty lips. Her skin is finely detailed with a dusting of small, delicate freckles across her cheeks and bridge of her nose. Her long, brunette wavy hair frames her face naturally. The lighting is warm and diffused, highlighting the subtle textures of her skin and the warmth in her eyes. Ultra-realistic, 8k, highly detailed skin texture, cinematic lighting.

Admiring, affectionate, obedient, submissive. No makeup, glimmer in her eyes.

sarah1a3, slender

Detailed, skinny model, pretty, cute, adorable.

ultra-realistic render, Hasselblad 500 C Planar"""

wf = json.loads(PATH.read_text())

# --- 1. identity block: drop the dead underboob triggers ---------------------
identity = wf["88"]["inputs"]["text"]
if "underbooba" in identity:
    if "score_9, score_8_up, score_7_up, underbooba, underboobs." not in identity:
        raise SystemExit("unexpected identity wording; refusing to guess.\n" + identity)
    identity = identity.replace(
        "score_9, score_8_up, score_7_up, underbooba, underboobs.",
        "score_9, score_8_up, score_7_up.",
        1,
    )
    wf["88"]["inputs"]["text"] = identity
    print("node 88: removed underbooba/underboobs")
else:
    print("node 88: underboob triggers already absent")

# --- 2. node 50: static face prompt, not the scene ---------------------------
current_50 = wf["50"]["inputs"].get("text")
if current_50 == FACE_PROMPT:
    print("node 50: face prompt already in place")
else:
    if current_50 != "{{prompt}}":
        raise SystemExit(f"node 50 holds {current_50!r}, expected '{{{{prompt}}}}'; refusing to guess")
    wf["50"]["inputs"]["text"] = FACE_PROMPT
    print("node 50: replaced {{prompt}} with the static face-portrait prompt")

PATH.write_text(json.dumps(wf, indent=2, sort_keys=True) + "\n")

# --- verify -----------------------------------------------------------------
wf = json.loads(PATH.read_text())
import re
tokens = sorted(set(re.findall(r"\{\{([A-Za-z0-9_]+)\}\}", PATH.read_text())))
print()
print("node  50 :", repr(wf["50"]["inputs"]["text"][:70]) + " ...")
print("node 111 :", repr(wf["111"]["inputs"]["text"]))
print("node  88 :", repr(wf["88"]["inputs"]["text"][:70]) + " ...")
print("tokens   :", tokens)
