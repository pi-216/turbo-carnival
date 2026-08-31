#!/usr/bin/env python3
"""Photo-realism / quality gate for turbo-carnival.

Scores freshly rendered images on:
  - aesthetic score   (shunk031/aesthetics-predictor-v1-vit-large-patch14,
                       ViT-L/14 -> AVA-trained scalar, roughly 1-10)
  - sharpness         (Laplacian variance on grayscale, resized to <=512px,
                       computed in numpy - no cv2/scipy dependency)
  - dimensions        (width/height sanity)

Usage:
  aesthetics_gate.py --model DIR --image PATH [--image PATH ...]
                     [--aesthetic-threshold 4.5] [--sharpness-threshold 30]

Prints one JSON object per image on stdout:
  {"path": ..., "aesthetic_score": 5.2, "sharpness": 120.4,
   "width": 816, "height": 1024,
   "decision": "accept"|"reject", "reason": "..."|null}
"""
import argparse
import json
import sys


def laplacian_variance(gray_pil):
    """Variance of the 4-neighbor Laplacian over a downscaled grayscale image.

    Pure numpy (no cv2/scipy): L = 4*center - up - down - left - right.
    High = sharp/edgy; low = blurry/soft.
    """
    import numpy as np

    img = gray_pil.convert("L")
    img.thumbnail((512, 512))
    a = np.asarray(img, dtype=np.float32)
    if a.shape[0] < 3 or a.shape[1] < 3:
        return 0.0
    center = a[1:-1, 1:-1]
    lap = (
        4.0 * center
        - a[:-2, 1:-1]
        - a[2:, 1:-1]
        - a[1:-1, :-2]
        - a[1:-1, 2:]
    )
    return float(lap.var())


def load_model(args):
    """Returns (processor, model) or raises. CPU-only, transformers remote code."""
    from transformers import AutoModel, AutoImageProcessor

    processor = AutoImageProcessor.from_pretrained(args.model, trust_remote_code=True)
    model = AutoModel.from_pretrained(args.model, trust_remote_code=True)
    model = model.to("cpu").eval()
    return processor, model


def score_image(path, processor, model):
    import torch
    from PIL import Image

    img = Image.open(path).convert("RGB")
    width, height = img.size

    if width < 64 or height < 64:
        return {
            "path": path,
            "aesthetic_score": None,
            "sharpness": None,
            "width": width,
            "height": height,
            "decision": "reject",
            "reason": f"dimensions too small {width}x{height}",
        }

    inputs = processor(images=img, return_tensors="pt")
    with torch.no_grad():
        out = model(**inputs)
    # v1 predictor exposes a single score tensor via logits (or first output).
    score_t = out.logits if hasattr(out, "logits") else out[0]
    score = float(score_t.reshape(-1)[0])

    sharpness = laplacian_variance(img)

    return {
        "path": path,
        "aesthetic_score": round(score, 4),
        "sharpness": round(sharpness, 2),
        "width": width,
        "height": height,
        "decision": None,
        "reason": None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--image", action="append", required=True)
    ap.add_argument("--aesthetic-threshold", type=float, default=4.5)
    ap.add_argument("--sharpness-threshold", type=float, default=30.0)
    args = ap.parse_args()

    try:
        import torch  # noqa: F401
        from PIL import Image, ImageFilter  # noqa: F401
    except Exception as e:  # pragma: no cover
        print(json.dumps({"error": f"deps: {e}"}))
        sys.exit(1)

    try:
        processor, model = load_model(args)
    except Exception as e:  # pragma: no cover
        print(json.dumps({"error": f"load: {e}"}))
        sys.exit(1)

    for path in args.image:
        try:
            info = score_image(path, processor, model)
            if info.get("decision"):
                print(json.dumps(info))
                sys.stdout.flush()
                continue

            reasons = []
            if info["aesthetic_score"] is not None and info["aesthetic_score"] < args.aesthetic_threshold:
                reasons.append(
                    f"aesthetic {info['aesthetic_score']} < {args.aesthetic_threshold}"
                )
            if info["sharpness"] is not None and info["sharpness"] < args.sharpness_threshold:
                reasons.append(
                    f"sharpness {info['sharpness']} < {args.sharpness_threshold}"
                )

            info["decision"] = "reject" if reasons else "accept"
            info["reason"] = "; ".join(reasons) if reasons else None
            print(json.dumps(info))
            sys.stdout.flush()
        except Exception as e:
            print(json.dumps({"path": path, "error": str(e)}))
            sys.stdout.flush()


if __name__ == "__main__":
    main()