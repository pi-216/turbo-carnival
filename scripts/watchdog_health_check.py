#!/usr/bin/env python3
"""Read-only overnight watchdog health checks. GET-only, short timeouts."""
import json
import urllib.request

CHECKS = [
    ("ComfyUI localhost:8188", "http://localhost:8188/system_stats"),
    ("Ollama game.localdomain:11434", "http://game.localdomain:11434/api/version"),
    ("Tunnel carnival.pi216.ai/up", "https://carnival.pi216.ai/up"),
]

def fetch(url, timeout=8):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            body = r.read(2048).decode("utf-8", "replace")
            return r.status, body
    except Exception as e:
        return None, str(e)

for name, url in CHECKS:
    status, body = fetch(url)
    if url.startswith("https") and status is not None:
        print(f"{name}: HTTP {status}")
    else:
        # For http URLs, try to parse JSON body to confirm service reachable
        ok = False
        try:
            json.loads(body)
            ok = True
        except Exception:
            pass
        if status is not None:
            print(f"{name}: HTTP {status} body_ok={ok}")
        else:
            print(f"{name}: ERROR {body}")