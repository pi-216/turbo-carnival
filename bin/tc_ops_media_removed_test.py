"""Branch test for check_platform_media_removed — no DB, no GPU, no network.

Monkeypatches the three side-effecting seams (psql, run, the report path) and
asserts every branch of the extended check: the stock condition, the per-post
condition (a removal masked by publishing), the steady state, and the
never-fabricate paths (rake failure / unreadable counts).

Usage: python3 tmp/test_platform_media_removed.py
"""
import importlib.util
import json
import sys
from pathlib import Path

APP = Path("/home/tim/source/activity/turbo-carnival")
spec = importlib.util.spec_from_file_location("tc_ops", APP / "bin" / "tc_ops.py")
tc = importlib.util.module_from_spec(spec)
sys.modules["tc_ops"] = tc
spec.loader.exec_module(tc)

fails = []


def check(name, got, want):
    ok = got == want
    print(f"  {'ok  ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" != {want!r}"))
    if not ok:
        fails.append(name)


def row(peak, newest, ours=150):
    return f"{peak}|{newest}|0.5|{ours}"


def line(listed, ours, missing, posts):
    return (f"MEDIA_INVENTORY listed={listed} ours={ours} missing={missing} "
            f"missing_posts={','.join(posts)} missing_media=")


def run_case(name, psql_row, rake_out, rc, prev_report, tmp_json):
    tc.psql = lambda sql, timeout=25: psql_row
    tc.run = lambda cmd, timeout=25, cwd=None: (rake_out, rc)
    tc.media_inventory_report = lambda: prev_report
    tc.MEDIA_INVENTORY_PATH = tmp_json
    out = tc.check_platform_media_removed()
    print(f"- {name}: {None if out is None else (out[0], out[1])}")
    return out, (json.loads(tmp_json.read_text()) if tmp_json.exists() else None)


tmp = Path("/tmp/tc_media_inv_test.json")
if tmp.exists():
    tmp.unlink()

print("A. stock shrinks (the 2026-09-24 shape) + per-post agrees")
out, written = run_case("stock+set", row(225, 200), line(200, 150, 36, ["312", "313"]),
                        0, None, tmp)
check("A.fires", out is not None, True)
check("A.headline-is-stock", "SHRANK" in out[1], True)
check("A.names-posts", "312,313" in out[3], True)
check("A.writes-report", written and written["missing_count"], 36)
check("A.first-run-newly-is-all-known-ids", written and written["newly_missing"], 2)

print("B. stock clean, one post removed in the same hour's publishing (the BLIND SPOT)")
tmp.unlink()
out, written = run_case("masked-removal", row(226, 226),
                        line(227, 150, 1, ["400"]), 0,
                        {"missing_posts": [], "measured_at": "2026-09-24T20:00:00Z"}, tmp)
check("B.fires", out is not None, True)
check("B.headline-is-set", "of ours are no longer" in out[1], True)
check("B.newly-is-delta", written and written["newly_missing"], 1)

print("C. steady state: nothing new, stock clean -> silent")
tmp.unlink()
out, _ = run_case("steady", row(226, 226), line(227, 150, 1, ["400"]), 0,
                  {"missing_posts": ["400"], "measured_at": "2026-09-24T20:00:00Z"}, tmp)
check("C.silent", out, None)

print("D. rake fails, stock clean -> silent (never fabricate a removal)")
tmp.unlink()
out, written = run_case("rake-failed", row(226, 226), "bin/rake aborted!", 1, None, tmp)
check("D.silent", out, None)
check("D.no-report-written", written, None)

print("E. rake fails, stock shrank -> still fires on the stock alone")
out, _ = run_case("rake-failed+stock", row(225, 200), "", 1, None, tmp)
check("E.fires", out is not None, True)
check("E.no-per-post-claim", "Per-post re-read" in out[3], False)

print("F. both counts unmeasured -> silent")
out, _ = run_case("unmeasured", "na|na|na|150", line(200, 150, 0, []), 0, None, tmp)
check("F.silent", out, None)

print("G. malformed rake output with stock clean -> silent")
out, _ = run_case("malformed", row(226, 226), "MEDIA_INVENTORY listed=x ours=y missing=z",
                  0, None, tmp)
check("G.silent", out, None)

if tmp.exists():
    tmp.unlink()
print(f"\n{'FAILURES: ' + ','.join(fails) if fails else 'all branches ok'}")
sys.exit(1 if fails else 0)
