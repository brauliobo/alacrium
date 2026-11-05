#!/bin/bash

# Incremental Alacrium Linux build wrapper.
# Keep using the same Chromium checkout and out/alacrium directory to avoid
# invalidating the object graph between version update attempts.

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [jobs] [--packages]"
  echo "Runs an incremental low-priority build in the existing out/alacrium directory."
  exit 0
fi

JOBS=6
BUILD_PACKAGES=0

for arg in "$@"; do
  case "$arg" in
    --packages)
      BUILD_PACKAGES=1
      ;;
    ''|*[!0-9]*)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [jobs] [--packages]" >&2
      exit 2
      ;;
    *)
      JOBS="$arg"
      ;;
  esac
done

ALACRIUM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR_SRC_DIR="${ALACRIUM_DIR}/chromium/src"

if [[ ! -f "$CR_SRC_DIR/out/alacrium/build.ninja" ]]; then
  echo "Missing $CR_SRC_DIR/out/alacrium/build.ninja; run gn gen once before incremental builds." >&2
  exit 2
fi

if ! command -v autoninja >/dev/null; then
  for depot_tools in "${DEPOT_TOOLS_DIR:-}" "$HOME/depot_tools" "$HOME/Projects/depot_tools"; do
    if [[ -n "$depot_tools" && -x "$depot_tools/autoninja" ]]; then
      export PATH="$depot_tools:$PATH"
      break
    fi
  done
fi
command -v autoninja >/dev/null || {
  echo "autoninja not found; set DEPOT_TOOLS_DIR or add depot_tools to PATH." >&2
  exit 2
}

export NINJA_SUMMARIZE_BUILD=1
export NINJA_STATUS="[%r processes, %f/%t @ %o/s | %e sec. ] "

cd "$CR_SRC_DIR"

run_ninja() {
  nice -n 10 ionice -c2 -n7 autoninja -C out/alacrium "$@" -j"$JOBS"
}

if [[ "$BUILD_PACKAGES" == 1 ]]; then
  run_ninja \
    clear_key_cdm \
    chromedriver \
    alacrium_shell \
    chrome/installer/linux:strip_chrome_binary \
    chrome/installer/linux:strip_chrome_sandbox \
    chrome/installer/linux:strip_chrome_management_service

  if [[ -f out/alacrium/chrome.stripped ]]; then
    ln -f out/alacrium/chrome.stripped out/alacrium/alacrium.stripped
  elif [[ ! -f out/alacrium/alacrium.stripped ]]; then
    echo "Missing stripped browser binary." >&2
    exit 1
  fi

  patchelf --remove-rpath out/alacrium/alacrium.stripped 2>/dev/null || true
  patchelf --remove-rpath out/alacrium/chrome_management_service.stripped 2>/dev/null || true

  cp -f "$ALACRIUM_DIR/logos/alacrium.svg" out/alacrium/alacrium.svg
  cp -f "$ALACRIUM_DIR/pak_src/binaries/pak" out/alacrium/pak
  cp -f "$ALACRIUM_DIR/infra/initial_preferences" out/alacrium/initial_preferences
  chmod 755 out/alacrium/pak

  if [[ ! -x buildtools/third_party/eu-strip/bin/eu-strip ]] &&
     command -v eu-strip >/dev/null; then
    mkdir -p buildtools/third_party/eu-strip/bin
    ln -sf "$(command -v eu-strip)" buildtools/third_party/eu-strip/bin/eu-strip
  fi

  run_ninja chrome/installer/linux:stable_deb chrome/installer/linux:stable_rpm
else
  run_ninja alacrium
fi
