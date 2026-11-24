#!/bin/bash
# Fast pre-PR checks for Alacrium Chromium rebases.
#
# Default mode is local-only and cheap. Pass --with-upstream to also run
# infra/diff_vs_upstream.sh and GN generation against the pinned/current target
# Chromium tag, or --with-gn to only add the GN generation check.

set -euo pipefail

cd "$(dirname "$0")/.."

WITH_UPSTREAM=0
WITH_GN=0
TARGET_TAG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-upstream)
      WITH_UPSTREAM=1
      WITH_GN=1
      ;;
    --with-gn)
      WITH_GN=1
      ;;
    --target)
      shift
      [ "$#" -gt 0 ] || { echo "--target needs a Chromium tag" >&2; exit 2; }
      TARGET_TAG="$1"
      ;;
    --help|-h)
      echo "Usage: $0 [--with-upstream] [--with-gn] [--target <chromium-tag>]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

list_local_check_files() {
  if command -v rg >/dev/null 2>&1; then
    rg --files . \
      -g '!arch-package-direct/**' \
      -g '!aur/**' \
      -g '!chromium-cl-*/**' \
      -g '!macos-build/**' \
      -g '!out/**'
  else
    git ls-files
  fi
}

echo "Checking shell syntax..."
bash -n trunk.sh version.sh upstream_version.sh setup.sh build_incremental.sh infra/*.sh

echo "Checking Python helper syntax..."
python3 -m py_compile \
  infra/extract_new_files_from_patch.py \
  infra/extract_alacrium_xtb.py \
  infra/merge_alacrium_xtb.py \
  infra/strip_dead_gn.py \
  infra/trim_hevc_patch.py

echo "Checking for local scratch files..."
[ ! -e .claude ] || fail ".claude/ must not be committed"
! list_local_check_files | rg -q '(^|/)_incompat/' || fail "_incompat scratch files remain"
! list_local_check_files | rg -q '\.(needs-port|disabled)$' || fail "deferred patch scratch files remain"

echo "Checking git whitespace outside patch payloads..."
git diff --check -- ':!other/*.patch'

if [ "$WITH_UPSTREAM" -eq 1 ]; then
  echo "Checking overlay and patch applicability against Chromium..."
  if [ -n "$TARGET_TAG" ]; then
    infra/diff_vs_upstream.sh "$TARGET_TAG"
  else
    infra/diff_vs_upstream.sh
  fi

  if rg --files out/upstream_diff/patch_status | rg '\.rc$' | xargs -r sh -c '
      for rc_file do
        [ "$(cat "$rc_file")" = 0 ] || exit 1
      done
    ' sh; then
    :
  else
    fail "one or more patches failed; see out/upstream_diff/patch_status"
  fi
fi

if [ "$WITH_GN" -eq 1 ]; then
  echo "Checking GN generation..."
  CR_SRC_DIR="$PWD/chromium/src"
  [ -d "$CR_SRC_DIR" ] || fail "missing $CR_SRC_DIR"
  GN_BIN=""
  if [ -x "$CR_SRC_DIR/buildtools/linux64/gn" ]; then
    GN_BIN="$CR_SRC_DIR/buildtools/linux64/gn"
  elif command -v gn >/dev/null 2>&1; then
    GN_BIN="$(command -v gn)"
  else
    fail "gn binary not found"
  fi

  if [ -f "$CR_SRC_DIR/out/alacrium/args.gn" ]; then
    ( cd "$CR_SRC_DIR" && "$GN_BIN" gen out/alacrium ) || fail "gn gen out/alacrium failed"
  else
    GN_TMP_OUT="out/.rebase_check_gn_$$"
    cleanup_gn_tmp() {
      rm -rf "$CR_SRC_DIR/$GN_TMP_OUT"
    }
    trap cleanup_gn_tmp EXIT
    mkdir -p "$CR_SRC_DIR/$GN_TMP_OUT"
    cp "$PWD/args.gn" "$CR_SRC_DIR/$GN_TMP_OUT/args.gn"
    ( cd "$CR_SRC_DIR" && "$GN_BIN" gen "$GN_TMP_OUT" ) || fail "gn gen failed"
    cleanup_gn_tmp
    trap - EXIT
  fi
fi

echo "OK"
