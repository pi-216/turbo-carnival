#!/usr/bin/env python3
"""Assess image quality for AI-generated content.

Returns JSON with blur score (Laplacian variance), resolution, contrast,
brightness, and a pass/fail determination.

Usage: python3 assess_image_quality.py <image_path> [--threshold 100]
"""

import argparse
import json
import sys
import os
import cv2
import numpy as np


def assess_image(image_path, blur_threshold=100):
    """Run all quality checks and return results dict."""
    results = {
        "path": image_path,
        "issues": [],
        "passed": True,
    }

    if not os.path.exists(image_path):
        return {"error": f"File not found: {image_path}"}

    img = cv2.imread(image_path)
    if img is None:
        return {"error": f"Cannot read image: {image_path}"}

    h, w = img.shape[:2]
    results["width"] = w
    results["height"] = h
    results["megapixels"] = round(w * h / 1_000_000, 2)

    # 1. Resolution check
    if w < 512 or h < 512:
        results["issues"].append(f"Resolution too low: {w}x{h}")
        results["passed"] = False

    # 2. Blur detection — Laplacian variance (industry standard)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    results["blur_score"] = round(laplacian_var, 2)

    if laplacian_var < blur_threshold:
        results["issues"].append(
            f"Blurry: Laplacian variance {laplacian_var:.1f} < {blur_threshold}"
        )
        results["passed"] = False

    # 3. Contrast check
    contrast = gray.std()
    results["contrast"] = round(contrast, 2)
    if contrast < 15:
        results["issues"].append(f"Low contrast: {contrast:.1f}")
        results["passed"] = False

    # 4. Brightness check (mean pixel intensity)
    brightness = gray.mean()
    results["brightness"] = round(brightness, 2)
    if brightness < 20:
        results["issues"].append(f"Too dark: brightness {brightness:.1f}")
        results["passed"] = False
    elif brightness > 240:
        results["issues"].append(f"Overexposed: brightness {brightness:.1f}")
        results["passed"] = False

    # 5. Compute a 0-100 quality score
    # Normalize blur to 0-100 (typical range: 0-1000 for Laplacian variance)
    blur_norm = min(laplacian_var / 500.0, 1.0) * 50  # 50% weight
    contrast_norm = min(contrast / 60.0, 1.0) * 25     # 25% weight
    brightness_ideal = 1.0 - abs(brightness - 128) / 128  # 0-1, 128 is ideal
    brightness_norm = brightness_ideal * 25             # 25% weight

    results["quality_score"] = round(blur_norm + contrast_norm + brightness_norm, 1)

    # Cap score
    if results["quality_score"] > 100:
        results["quality_score"] = 100
    elif results["quality_score"] < 0:
        results["quality_score"] = 0

    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Assess image quality")
    parser.add_argument("image_path", help="Path to image file")
    parser.add_argument(
        "--threshold", type=float, default=100,
        help="Blur threshold (Laplacian variance, default 100)"
    )
    args = parser.parse_args()

    result = assess_image(args.image_path, args.threshold)
    print(json.dumps(result))
    sys.exit(0 if result.get("passed", False) else 1)
