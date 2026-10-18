#!/usr/bin/env python3
"""Compare the Sarah (API) and Lily (canvas) inpaint paths, parameter by parameter.

Both files carry their own parameter NAMES -- the API format names inputs directly, and the canvas
format includes `inputs[].widget` names -- so values are paired by name, never by position.
"""
import json
import pathlib

SARAH = pathlib.Path("/home/tim/source/activity/turbo-carnival/comfy_workflows/turbo_one_step_v2/step1_generate.json")
LILY = pathlib.Path("/mnt/fscache/essdee/ComfyUI/user/default/workflows/turbo-one-step-Lily.json")


def load_api(p):
    return {nid: {"type": n.get("class_type", ""),
                  "params": {k: v for k, v in (n.get("inputs") or {}).items()
                             if not (isinstance(v, list) and len(v) == 2 and isinstance(v[0], str))},
                  "links": [k for k, v in (n.get("inputs") or {}).items()
                            if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str)]}
            for nid, n in json.loads(p.read_text()).items()}


def load_canvas(p):
    wf = json.loads(p.read_text())
    out = {}
    for n in wf.get("nodes", []):
        names = [i.get("name") for i in (n.get("inputs") or []) if i.get("widget") is not None]
        vals = n.get("widgets_values") or []
        params = {}
        for i, nm in enumerate(names):
            if i < len(vals):
                params[nm] = vals[i]
        out[str(n.get("id"))] = {"type": n.get("type", ""), "params": params,
                                 "links": [i.get("name") for i in (n.get("inputs") or [])
                                           if i.get("widget") is None]}
    return out


sarah, lily = load_api(SARAH), load_canvas(LILY)

CLASSES = [
    "ApplyCLIPSeg+", "GrowMaskWithBlur", "Bounded Image Crop with Mask", "Bounded Image Blend",
    "ImageResize+", "BasicScheduler", "SamplerCustomAdvanced", "SetLatentNoiseMask", "ImageToMask",
    "MaskToImage", "LazySwitchKJ", "Text Multiline", "ControlNetLoader", "ControlNetApplyAdvanced",
    "OpenPose - Get poses", "ImageUpscaleWithModel", "UpscaleModelLoader", "ImageScale", "KSampler",
    "CLIPSetLastLayer", "ImageBatch", "ImageScaleBy",
]


def show(label, wf):
    print("=" * 78)
    print("%s  (%d nodes)" % (label, len(wf)))
    print("=" * 78)
    for cls in CLASSES:
        hits = [(nid, n) for nid, n in sorted(wf.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)
                if n["type"] == cls]
        if not hits:
            continue
        print()
        print("--- %s  x%d" % (cls, len(hits)))
        for nid, n in hits:
            keys = ("prompt", "threshold", "dilate", "blur", "smooth", "expand", "blur_radius",
                    "tapered_corners", "padding_left", "padding_right", "padding_top", "padding_bottom",
                    "blend_factor", "feathering", "width", "height", "method", "scheduler", "steps",
                    "denoise", "channel", "switch", "text", "control_net_name", "strength",
                    "start_percent", "end_percent", "positive", "negative", "image", "unique_id",
                    "vae", "upscale_model", "image1", "image2", "upscale_method", "ckpt_name", "stop_at_clip_layer")
            keep = {k: n["params"][k] for k in keys if k in n["params"]}
            print("  id %-6s %s" % (nid, keep if keep else (n["params"] or n["links"])))


show("SARAH  (api, repo file)", sarah)
print()
show("LILY  (canvas, current)", lily)

print()
print("=" * 78)
print("EXTRAS: classes present in one but not the other")
print("=" * 78)
ts = {n["type"] for n in sarah.values()}
tl = {n["type"] for n in lily.values()}
print("  only in LILY  : %s" % sorted(tl - ts))
print("  only in SARAH : %s" % sorted(ts - tl))
