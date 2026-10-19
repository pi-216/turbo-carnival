#!/usr/bin/env python3
"""NSFW gate for turbo-carnival using Falconsai/nsfw_image_detection (ViT-base).

Usage:
  nsfw_gate.py --model DIR [--threshold 0.5] --image PATH [--image PATH ...]

Prints one JSON object per image on stdout:
  {"path": ..., "label": "nsfw"|"normal", "nsfw_score": 0.0-1.0, "decision": "reject"|"accept"}
"""
import argparse
import json
import sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--image", action="append", required=True)
    ap.add_argument("--threshold", type=float, default=0.5)
    args = ap.parse_args()

    try:
        import torch  # noqa: F401
        from transformers import AutoImageProcessor, AutoModelForImageClassification
    except Exception as e:  # pragma: no cover
        print(json.dumps({"error": f"deps: {e}"}))
        sys.exit(1)

    try:
        processor = AutoImageProcessor.from_pretrained(args.model)
        model = AutoModelForImageClassification.from_pretrained(args.model)
        # Always classify on CPU: the RTX 4090 is VRAM-tight under ComfyUI.
        model = model.to("cpu").eval()
    except Exception as e:
        print(json.dumps({"error": f"load: {e}"}))
        sys.exit(1)

    from PIL import Image
    import torch

    id2label = model.config.id2label or {0: "normal", 1: "nsfw"}

    for path in args.image:
        try:
            img = Image.open(path).convert("RGB")
            inputs = processor(images=img, return_tensors="pt")
            with torch.no_grad():
                logits = model(**inputs).logits
            probs = torch.softmax(logits, dim=-1)[0]
            label_idx = int(logits.argmax(dim=-1)[0])
            label = id2label.get(label_idx, str(label_idx))
            # nsfw_score = probability of the class whose id2label == 'nsfw'
            nsfw_score = 0.0
            for idx, lbl in id2label.items():
                if lbl == "nsfw":
                    nsfw_score = float(probs[idx])
                    break
            out = {
                "path": path,
                "label": label,
                "nsfw_score": round(nsfw_score, 4),
                "decision": "reject" if nsfw_score >= args.threshold else "accept",
            }
            print(json.dumps(out))
            sys.stdout.flush()
        except Exception as e:
            print(json.dumps({"path": path, "error": str(e)}))
            sys.stdout.flush()

if __name__ == "__main__":
    main()