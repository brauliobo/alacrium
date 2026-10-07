#!/bin/bash
# Compare Alacrium's src/ overlay against an upstream Chromium checkout.
#
# Prereqs: run ./trunk.sh first so chromium/src holds a Chromium checkout.
# Pass a different tag as $1 to compare
# the overlay against a target rebase tag instead of the current ALACRIUM_VER.
#
# Output: out/upstream_diff/
#   inventory.tsv   status per overlay file (NEW|MOD|SAME|MISSING_UPSTREAM)
#   summary.md      per-area counts
#   diffs/<path>    one unified diff per modified file
#   patch_status/   `git apply --check` result for every patch in other/

set -euo pipefail
cd "$(dirname "$0")/.."
ALACRIUM_ROOT="$PWD"

CR_SRC_DIR="${ALACRIUM_ROOT}/chromium/src"
TARGET_TAG="${1:-$(awk -F\" '/^ALACRIUM_VER=/{print $2}' version.sh)}"

[ -d "$CR_SRC_DIR/.git" ] || { echo "No chromium checkout at $CR_SRC_DIR — run ./trunk.sh first." >&2; exit 1; }

OUT="$ALACRIUM_ROOT/out/upstream_diff"
rm -rf "$OUT" && mkdir -p "$OUT/diffs" "$OUT/patch_status"

echo "Comparing overlay against chromium tag: $TARGET_TAG"
if ! ( cd "$CR_SRC_DIR" && git rev-parse -q --verify "refs/tags/$TARGET_TAG" >/dev/null ); then
  ( cd "$CR_SRC_DIR" && git fetch --depth=1 origin "refs/tags/$TARGET_TAG:refs/tags/$TARGET_TAG" )
fi

list_overlay_files() {
  if command -v rg >/dev/null 2>&1; then
    rg --files src
  else
    find src -type f
  fi
}

: > "$OUT/inventory.tsv"
while IFS= read -r rel; do
  sub="${rel#src/}"
  if ! git -C "$CR_SRC_DIR" cat-file -e "refs/tags/$TARGET_TAG:$sub" 2>/dev/null; then
    status=NEW
  elif git -C "$CR_SRC_DIR" show "refs/tags/$TARGET_TAG:$sub" | cmp -s "$rel" -; then
    status=SAME
  else
    status=MOD
    mkdir -p "$OUT/diffs/$(dirname "$sub")"
    diff -u <(git -C "$CR_SRC_DIR" show "refs/tags/$TARGET_TAG:$sub") "$rel" \
      > "$OUT/diffs/$sub.diff" || true
  fi
  printf '%s\t%s\n' "$status" "$sub" >> "$OUT/inventory.tsv"
done < <(list_overlay_files | sort)

awk -F'\t' '{n[$1]++} END{for (k in n) print k, n[k]}' "$OUT/inventory.tsv" > "$OUT/summary.counts"

check_patch_group() {
  local patch_dir="$1"
  shift

  local patch_index
  patch_index=$(mktemp)
  GIT_INDEX_FILE="$patch_index" git -C "$patch_dir" read-tree HEAD

  local patch_file name rc
  for patch_file in "$@"; do
    name=$(basename "$patch_file")
    if GIT_INDEX_FILE="$patch_index" git -C "$patch_dir" apply --cached --recount \
        "$ALACRIUM_ROOT/$patch_file" 2> "$OUT/patch_status/$name.err"; then
      echo 0 > "$OUT/patch_status/$name.rc"
    else
      rc=$?
      echo "$rc" > "$OUT/patch_status/$name.rc"
    fi
  done

  rm -f "$patch_index"
}

# Check the active patches in setup.sh order so later patches see earlier changes.
check_patch_group "$CR_SRC_DIR/third_party/ffmpeg" \
  other/add-hevc-ffmpeg-decoder-parser.patch

check_patch_group "$CR_SRC_DIR" \
  other/fix-policy-templates.patch \
  other/ftp-support.patch \
  other/open_in_same_tab.patch \
  other/content-shell-branding.patch \
  other/alacrium_webui.patch \
  other/keyboard_shortcuts.patch \
  other/GPC.patch \
  other/disable-privacy-sandbox.patch \
  other/enable-vaapi-nvidia-default.patch \
  other/history-query-dedupe.patch \
  other/history-sync-redirect-chain-limit.patch \
  other/history-delete-directive-startup-guard.patch \
  other/google-api-keys-defaults.patch \
  other/fix_disable_aero_crash.patch

{
  echo "# Upstream diff summary — $TARGET_TAG"
  echo
  echo "## Overlay file status"
  awk -F'\t' '{n[$1]++} END{for (k in n) printf "- %s: %d\n", k, n[k]}' "$OUT/inventory.tsv"
  echo
  echo "## Per-area modification counts"
  awk -F'\t' '$1=="MOD"{split($2,a,"/"); c[a[1]]++} END{for (k in c) printf "- %s: %d\n", k, c[k]}' "$OUT/inventory.tsv" | sort
  echo
  echo "## Patch applicability"
  for f in "$OUT/patch_status"/*.rc; do
    rc=$(cat "$f"); name=$(basename "$f" .rc)
    [ "$rc" = 0 ] && echo "- OK   $name" || echo "- FAIL $name"
  done
} > "$OUT/summary.md"

echo "Wrote $OUT/summary.md"
