#!/usr/bin/env bash
# corpus_backup.sh -- put a SECOND copy of the Sarah render corpus somewhere the
# NAS volume cannot take with it.
#
# WHY THIS EXISTS
# /mnt/nas-ai-models/comfyui-output is the only copy of every photo this account
# has posted or could post. The nightly /home/tim/backup.sh rsyncs
# /mnt/fscache/essdee/ WITHOUT --copy-links, and `-x` stops the walk at the
# filesystem boundary, so ComfyUI/output (a symlink into that NAS tree) is
# mirrored as a DANGLING symlink: the backup LOOKS like it covers the images and
# covers none of them. Even with --copy-links the target (~/backup/essdee, on the
# NAS home) is on the SAME volume as the source, so it is not redundancy against
# a volume loss. Measured 2026-09-21: 168 of the 339 rows in `photos` are already
# unresolvable (66 of them pointed at /tmp); the 171 that survive total 176 MiB.
#
# WHAT IT DOES
# Hardlink snapshots of the corpus onto a device that is NOT the NAS.
#   - `-L` follows symlinks, so real BYTES land in the copy. That is the whole
#     point: the defect being fixed is a copy that is only a symlink.
#   - `--link-dest` makes each snapshot cost only what CHANGED. This matters
#     here because PhotoAssetMarker mutates a published asset in place
#     (temp-file + atomic rename), which BREAKS the hardlink -- so an earlier
#     snapshot keeps the pre-mark bytes instead of being silently overwritten.
#     A plain mirror loses that history; a snapshot does not.
#   - The DATABASE defines "the corpus": every `photos.path` that still resolves
#     must be present in the new snapshot. A missing one FAILS the run, so the
#     script cannot report success while the thing it exists to protect is gone.
#
# WHERE THE COPY GOES
# <repo>/corpus-backup/ -- inside the codebase, on the game box's local NVMe
# (ubuntu-vg). That is a different MACHINE and a different DEVICE from the NAS,
# so it covers a NAS volume loss, a NAS box failure, and an accidental `rm -rf`
# of comfyui-output. It does NOT cover this box dying: for that, use --offsite.
#
# CREDENTIAL, corrected 2026-09-21: the APP's B2 keys are dead (the key in .env
# and the one in Rails credentials are the same id; aws s3 ls on
# fluffy-train-development/-production -> InvalidAccessKeyId, Rails' own b2
# service.exist? -> Forbidden, nothing written to B2 since 2026-05-28). But the
# earlier conclusion on the board -- "off-site needs NEW credentials, no agent
# can obtain those from here" -- was WRONG about this box: ~/.aws/credentials
# holds the profile `b2_tim`, a LIVE key for the SAME B2 account
# (float 37451bb92cd0; `aws s3 ls --profile b2_tim --endpoint-url
# https://s3.us-west-004.backblazeb2.com` lists the account's 6 buckets, rc=0),
# and every sibling project already has a prefix in `tim-training-data/`.
# Off-site therefore needs no new credential -- only approval to write into
# Tim's B2 account, which is why --offsite is OFF by default and runs only when
# explicitly asked (see photo-corpus-offsite-gap). Until it is approved, the
# bar this script claims is two independent devices, no more.
# The directory is gitignored -- machine-local data, never source.
#
# HISTORY WITHOUT DELETING ANYTHING
# Snapshots live in seven fixed weekday slots (snapshots/mon ... snapshots/sun).
# A run rsyncs into TODAY'S slot, so the eighth run onward reuses a slot and
# rsync replaces what changed inside it. The ring is bounded and this script
# contains no delete logic of its own. Bytes are shared between slots by
# hardlink, so seven slots cost about one tree plus the changes since.
#
# USAGE
#   bin/corpus_backup.sh                  # snapshot into today's slot
#   bin/corpus_backup.sh --dry-run        # show what would move, change nothing
#   bin/corpus_backup.sh --verify-only    # re-check the newest slot against the DB
#   bin/corpus_backup.sh --list           # slots, newest first
#   bin/corpus_backup.sh --offsite --dry-run   # show how the off-site upload would go
#   bin/corpus_backup.sh --offsite             # archive + upload + read back
#   CORPUS_BACKUP_OFFSITE=1 bin/corpus_backup.sh   # snapshot, then the off-site leg
#   CORPUS_BACKUP_DEST=/mnt/models/corpus bin/corpus_backup.sh
#
# NOT IN SCOPE: the other projects' trees under comfyui-output (A1111, unnamed,
# toy, ...). They are large and belong to other work. If the DB ever references a
# path outside this script's includes, the verification step reports it.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${CORPUS_BACKUP_SRC:-/mnt/nas-ai-models/comfyui-output}"
DEST="${CORPUS_BACKUP_DEST:-$APP/corpus-backup}"
DB="${TC_DB:-turbo_carnival_development}"
# The files that ARE this account's corpus. An explicit list, so "what is
# protected" is auditable rather than implied by a clever pattern.
INCLUDES=(
  --include='/gen-*.png'
  --include='/sarah1a3/'
  --include='/sarah1a3/***'
  --exclude='*'
)

SNAP_ROOT="$DEST/snapshots"
MANIFEST="$DEST/corpus-paths.txt"

die() { printf 'corpus_backup: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'corpus_backup: %s\n' "$*"; }

# --- the corpus, as the database defines it ---------------------------------
# Written even when the DB is unreadable (then absent), because a manifest that
# silently disappears is worse than one that is visibly missing.
write_manifest() {
  mkdir -p "$DEST" || die "cannot create $DEST"
  if ! psql -d "$DB" -tAc "select path from photos where path is not null;" \
       > "$MANIFEST.tmp" 2>/dev/null; then
    rm -f "$MANIFEST.tmp"
    log "WARN: could not read database $DB -- corpus verification will be SKIPPED"
    return 1
  fi
  mv "$MANIFEST.tmp" "$MANIFEST"
  return 0
}

# Every resolvable DB path must exist under $1. Prints what is missing.
verify_against() {
  local root="$1" missing=0 checked=0
  [ -s "$MANIFEST" ] || { log "WARN: no manifest -- cannot verify"; return 2; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || continue                 # already-lost rows are not this script's fault
    checked=$((checked + 1))
    local rel="${p#*/output/}"              # path as it sits under comfyui-output
    if [ ! -f "$root/$rel" ]; then
      missing=$((missing + 1))
      [ "$missing" -le 10 ] && log "MISSING from copy: $rel"
    fi
  done < "$MANIFEST"
  log "verified $checked resolvable corpus file(s); missing=$missing"
  [ "$missing" -eq 0 ] || return 1
  return 0
}

# The most recently WRITTEN slot other than $1 -- the cheapest hardlink source.
newest_slot() {
  local exclude="${1:-}" best="" best_t=0 t
  for d in "$SNAP_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ "${d%/}" = "$SNAP_ROOT/$exclude" ] && continue
    t=$(stat -c %Y "$d" 2>/dev/null || echo 0)
    if [ "$t" -gt "$best_t" ]; then best_t="$t"; best="${d%/}"; fi
  done
  printf '%s' "$best"
}

# --- off-site (opt-in; writes into Tim's B2 account only when asked) ----------
# The corpus as the DATABASE defines it -- every resolvable `photos.path`, the
# same set verify_against() demands -- packed into one archive and uploaded to a
# store that is neither this box nor the NAS. Scope is deliberate: the ~83 GB
# historical sarah1a3 render tree stays on the two local copies, because
# off-siting it is a recurring cost decision, while the ~176 MiB the app can
# actually publish is not. The object is READ BACK after upload and its size and
# sha256 compared, because an upload nobody read back is a claim, not a copy.
OFFSITE_BUCKET="${CORPUS_BACKUP_BUCKET:-tim-training-data}"
OFFSITE_PREFIX="${CORPUS_BACKUP_PREFIX:-turbo-carnival/corpus}"
OFFSITE_PROFILE="${CORPUS_BACKUP_PROFILE:-b2_tim}"
OFFSITE_ENDPOINT="${CORPUS_BACKUP_ENDPOINT:-https://s3.us-west-004.backblazeb2.com}"
OFFSITE_DIR="$DEST/offsite"
OFFSITE_ARCHIVE=""          # set by build_offsite_archive; never via stdout --
                            # log() writes to stdout, so a `$(...)` capture would
                            # return "<log line>\n<path>" (the harness hit exactly
                            # that bug on an adopted job id).

aws_() { aws --profile "$OFFSITE_PROFILE" --endpoint-url "$OFFSITE_ENDPOINT" "$@"; }

build_offsite_archive() {
  write_manifest || die "off-site copy needs the DB manifest"
  mkdir -p "$OFFSITE_DIR" || die "cannot create $OFFSITE_DIR"
  local stamp list rel n=0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  list="$OFFSITE_DIR/.corpus-list-$stamp"
  : > "$list"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || continue                  # already-lost rows are not ours to ship
    rel="${p#*/output/}"
    if [ -f "$SRC/$rel" ]; then
      printf '%s\n' "$rel" >> "$list"
      n=$((n + 1))
    else
      log "WARN: off-site: skipping unresolvable $p"
    fi
  done < "$MANIFEST"
  [ "$n" -gt 0 ] || die "off-site copy: no resolvable corpus file to archive"
  cp "$MANIFEST" "$OFFSITE_DIR/corpus-paths.txt"
  OFFSITE_ARCHIVE="$OFFSITE_DIR/corpus-$stamp.tar.gz"
  tar -czf "$OFFSITE_ARCHIVE" -C "$SRC" -T "$list" -C "$OFFSITE_DIR" corpus-paths.txt \
    || die "off-site copy: tar failed"
  rm -f "$list"
  log "off-site: archived $n corpus file(s) + the DB manifest"
}

run_offsite() {                             # $1 = 1 for a dry run
  local dry="${1:-0}" key sha size got meta
  build_offsite_archive
  key="${OFFSITE_PREFIX}/$(basename "$OFFSITE_ARCHIVE")"
  sha=$(sha256sum "$OFFSITE_ARCHIVE" | cut -d' ' -f1)
  size=$(stat -c %s "$OFFSITE_ARCHIVE")
  log "off-site: archive $OFFSITE_ARCHIVE ($size bytes, sha256=$sha)"
  log "off-site: target s3://$OFFSITE_BUCKET/$key (profile $OFFSITE_PROFILE)"
  if [ "$dry" -eq 1 ]; then
    aws_ s3 cp --dryrun "$OFFSITE_ARCHIVE" "s3://$OFFSITE_BUCKET/$key" \
      || die "off-site copy: dry run failed"
    log "DRY RUN -- nothing was uploaded"
    return 0
  fi
  aws_ s3 cp "$OFFSITE_ARCHIVE" "s3://$OFFSITE_BUCKET/$key" --metadata "sha256=$sha" \
    || die "off-site copy: upload failed"
  got=$(aws_ s3api head-object --bucket "$OFFSITE_BUCKET" --key "$key" \
        --query 'ContentLength' --output text) \
    || die "off-site copy: cannot read the object back"
  meta=$(aws_ s3api head-object --bucket "$OFFSITE_BUCKET" --key "$key" \
        --query 'Metadata.sha256' --output text)
  [ "$got" = "$size" ] || die "off-site copy: uploaded size $got != local $size"
  [ "$meta" = "$sha" ] || die "off-site copy: uploaded sha256 $meta != local $sha"
  log "OK: off-site copy verified -- s3://$OFFSITE_BUCKET/$key ($got bytes, sha256 matches)"
}

# --- modes -------------------------------------------------------------------
case "${1:-}" in
  --offsite)
    # Standalone off-site copy. `--dry-run` builds the archive locally and shows
    # the exact upload (auth exercised, nothing written to the bucket).
    if [ "${2:-}" = "--dry-run" ]; then run_offsite 1; else run_offsite 0; fi
    exit $? ;;
  --list)
    [ -d "$SNAP_ROOT" ] || { log "no snapshots yet in $SNAP_ROOT"; exit 0; }
    for d in "$SNAP_ROOT"/*/; do
      [ -d "$d" ] || continue
      printf '%s  %8s  %s\n' "$(stat -c %y "${d%/}" | cut -d. -f1)" \
        "$(du -sh "${d%/}" 2>/dev/null | cut -f1)" "${d%/}"
    done | sort -r
    exit 0 ;;
  --verify-only)
    s=$(newest_slot)
    [ -n "$s" ] || die "no snapshot to verify"
    write_manifest || true
    verify_against "$s" || die "verification FAILED against $s"
    log "OK: $s matches the corpus"
    exit 0 ;;
  --dry-run) DRY=1 ;;
  "") DRY=0 ;;
  *) die "unknown argument: $1" ;;
esac

# --- preflight ---------------------------------------------------------------
[ -d "$SRC" ] || die "source tree not found: $SRC (is the NAS mounted?)"
command -v rsync >/dev/null || die "rsync not installed"

write_manifest || true

SLOT=$(date +%a | tr '[:upper:]' '[:lower:]')     # mon..sun
SNAP="$SNAP_ROOT/$SLOT"
PREV=$(newest_slot "$SLOT")

LINK_OPT=()
[ -n "$PREV" ] && [ -d "$PREV" ] && LINK_OPT=(--link-dest="$PREV")

log "source : $SRC"
log "dest   : $SNAP (slot $SLOT)"
[ -n "${LINK_OPT[0]:-}" ] && log "link   : $PREV (only changes are stored)"

RSYNC=(rsync -a -L --delete-excluded --stats --human-readable
       "${LINK_OPT[@]}" "${INCLUDES[@]}")

if [ "$DRY" -eq 1 ]; then
  log "DRY RUN -- nothing will be written"
  "${RSYNC[@]}" --dry-run "$SRC/" "$SNAP/" | tail -25
  exit 0
fi

mkdir -p "$SNAP" || die "cannot create $SNAP"
"${RSYNC[@]}" "$SRC/" "$SNAP/" || die "rsync failed"

# The copy is not a success until the thing it protects is actually in it.
if ! verify_against "$SNAP"; then
  die "copy is INCOMPLETE -- $SNAP is NOT a valid snapshot (left in place for inspection)"
fi

log "OK: snapshot $SNAP"
du -sh "$SNAP" 2>/dev/null || true

# The off-site leg is OFF unless explicitly enabled: it writes into Tim's B2
# account, and that is an approval to obtain, not a default to assume
# (photo-corpus-offsite-gap).
if [ "${CORPUS_BACKUP_OFFSITE:-0}" = "1" ]; then
  run_offsite 0 || die "off-site copy FAILED (the local snapshot above is still valid)"
fi