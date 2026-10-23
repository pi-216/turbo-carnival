#!/usr/bin/env bash
# Regression test for bin/prd_link (ticket #121) — no token, no network.
#
# Proves the four things the ticket names:
#   (a) edges are set,
#   (b) a PRD's own ticket stays top-level and is never linked to itself,
#   (c) a deliberately dropped edge is repaired by --apply,
#   (d) --check exits non-zero on that dropped edge.
#
# Run from anywhere:  .github/scripts/test-prd-link.sh
# It puts a stubbed `gh` first on PATH, so the real CLI is never reached.
#
# The sabotage run is part of the suite, not a separate ceremony:
#   STUB_BREAK_LINK=1 .github/scripts/test-prd-link.sh   → must FAIL
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINK="$ROOT/bin/prd_link"
STUB="$ROOT/.github/scripts/stub-gh"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

assert_contains() { # label needle haystack
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to find [$2] in [$3]" ;; esac
}

assert_missing() { # label needle haystack
  case "$3" in *"$2"*) bad "$1" "did not expect [$2] in [$3]" ;; *) ok "$1" ;; esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export STUB_DIR="$work"
mkdir -p "$work/bin"

# --- fixtures -------------------------------------------------------------
# PRD 0006 (#75) owns two open children; #75 ALSO carries prd:0006, which is the
# "link the PRD to itself" trap. PRD 0007 (#113) is closed with no open children.
cat >"$work/prd_tickets.json" <<'JSON'
[{"number":75,"title":"[PRD] PRD 0006 — Harness conformance","state":"OPEN"},
 {"number":113,"title":"[PRD] PRD 0007 — Safety posture","state":"CLOSED"},
 {"number":90,"title":"W1.4 an ordinary ticket, not a PRD","state":"OPEN"}]
JSON
cat >"$work/children.json" <<'JSON'
[{"number":75,"labels":[{"name":"prd:0006"}]},
 {"number":84,"labels":[{"name":"prd:0006"},{"name":"ticket"}]},
 {"number":85,"labels":[{"name":"prd:0006"},{"name":"ticket"}]},
 {"number":91,"labels":[{"name":"bug"}]}]
JSON
: >"$work/links.txt"

ln -sf "$STUB" "$work/bin/gh"
export PATH="$work/bin:$PATH"
run() { "$LINK" --repo pi-216/turbo-carnival "$@"; }

echo "test-prd-link"

# --- (d) an empty edge set is drift, and --check says so -------------------
out="$(run --check)"; rc=$?
assert_eq "check exits 1 when edges are missing" 1 "$rc"
assert_contains "check names the missing children" "missing=#84,#85" "$out"

# --- (a) --apply sets the edges -------------------------------------------
out="$(run --apply)"; rc=$?
assert_eq "apply exits 0" 0 "$rc"
assert_contains "apply reports two repaired" "repaired=2" "$out"
if grep -qx '75:84' "$work/links.txt" && grep -qx '75:85' "$work/links.txt"; then
  ok "apply wrote both edges"
else
  bad "apply wrote both edges" "$(tr '\n' ' ' <"$work/links.txt")"
fi

# --- (b) the PRD's own ticket is never linked to itself -------------------
assert_missing "the PRD ticket is not its own child" "75:75" "$(cat "$work/links.txt")"

# --- convergence: a re-run changes nothing --------------------------------
out="$(run --apply)"; rc=$?
assert_eq "second apply exits 0" 0 "$rc"
assert_contains "second apply repairs nothing" "repaired=0" "$out"
assert_eq "second apply skips both" "skipped=2" "$(printf '%s' "$out" | grep -o 'skipped=[0-9]*')"

out="$(run --check)"; rc=$?
assert_eq "check is green once converged" 0 "$rc"

# --- (c) a dropped edge is repaired by the re-run ------------------------
grep -v '^75:85$' "$work/links.txt" >"$work/links.new" && mv "$work/links.new" "$work/links.txt"
out="$(run --check)"; rc=$?
assert_eq "check goes red on a dropped edge" 1 "$rc"
assert_contains "check names only the dropped edge" "missing=#85" "$out"

out="$(run --apply)"; rc=$?
assert_eq "apply repairs the dropped edge" 0 "$rc"
assert_contains "apply reports one repaired" "repaired=1" "$out"
assert_contains "apply still skips the one already there" "skipped=1" "$out"
grep -qx '75:85' "$work/links.txt" && ok "the dropped edge is back" || bad "the dropped edge is back"

# --- a PRD ticket that carries a parent is a violation -------------------
printf '113:44\n' >"$work/parents.txt"
out="$(run --check)"; rc=$?
assert_eq "check exits 1 when a PRD ticket has a parent" 1 "$rc"
assert_contains "check names the offending PRD" "must stay top-level" "$out"
rm -f "$work/parents.txt"

# --- no remote and no --repo must fail loudly, not guess -----------------
norepo="$work/norepo"
mkdir -p "$norepo"
( cd "$norepo" && git init -q . && "$LINK" --check >/dev/null 2>"$work/err" )
rc=$?
assert_eq "no origin remote exits 2" 2 "$rc"
assert_contains "no origin remote says so" 'no `origin` remote' "$(cat "$work/err")"

# --- a remote but no docs/prd must not report a vacuous ok ---------------
noprd="$work/noprd"
mkdir -p "$noprd"
( cd "$noprd" && git init -q . \
    && git remote add origin git@github.com:pi-216/turbo-carnival.git \
    && "$LINK" --check >/dev/null 2>"$work/err2" )
rc=$?
assert_eq "no docs/prd exits 2" 2 "$rc"
assert_contains "no docs/prd names the directory" "docs/prd is missing" "$(cat "$work/err2")"

echo
if [ "$fail" -eq 0 ]; then
  echo "TESTS OK ($pass assertions)"
  exit 0
fi
echo "TESTS RED ($fail failed, $pass passed)"
exit 1
