#!/usr/bin/env bash

set -euo pipefail

export HOME=/home/braulio
alacrium_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aur_src_dir="${alacrium_dir}/aur/alacrium-browser"
aur_bin_dir="${alacrium_dir}/aur/alacrium-browser-bin"
state_dir=/home/braulio/.local/state/alacrium-updater
lock_file="${state_dir}/update.lock"
last_message="${state_dir}/last-message.md"
release_api="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Linux&num=1"

mkdir -p "$state_dir"

export PATH="/home/braulio/.local/bin:/home/braulio/bin:/usr/local/bin:/usr/bin:/bin"
export SSH_ASKPASS=/usr/bin/ksshaskpass
export SSH_ASKPASS_REQUIRE=force
export GIT_ASKPASS="${GIT_ASKPASS:-$SSH_ASKPASS}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -i /home/braulio/.ssh/id_github -o IdentitiesOnly=yes}"

if command -v systemctl >/dev/null 2>&1; then
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*|WAYLAND_DISPLAY=*|XDG_CURRENT_DESKTOP=*|KDE_FULL_SESSION=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XAUTHORITY=*)
        export "$line"
        ;;
    esac
  done < <(systemctl --user show-environment 2>/dev/null || true)
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export DISPLAY="${DISPLAY:-:0}"

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another Alacrium update run is active; exiting."
  exit 0
fi

echo "$(date -Is) starting Alacrium updater"

git -C "$alacrium_dir" switch main
git -C "$alacrium_dir" pull --ff-only origin main

read_alacrium_ver() {
  sed -nE 's/^ALACRIUM_VER="([^"]+)"/\1/p'
}

committed_version="$(git -C "$alacrium_dir" show HEAD:version.sh | read_alacrium_ver)"
working_version="$(read_alacrium_ver < "${alacrium_dir}/version.sh")"
latest_version="$(
  curl -fsSL "$release_api" | python3 -c '
import json
import re
import sys

try:
    releases = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if not releases:
    sys.exit(1)

version = releases[0].get("version", "")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit(1)

print(version)
'
)"

if [ -z "$committed_version" ] || [ -z "$working_version" ]; then
  echo "Could not read Alacrium version from ${alacrium_dir}/version.sh" >&2
  exit 1
fi

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

printf 'Committed Alacrium version: %s\n' "$committed_version"
printf 'Working-tree Alacrium version: %s\n' "$working_version"
printf 'Latest Chromium stable Linux version: %s\n' "$latest_version"

pending_local_update=0
if [ "$working_version" != "$committed_version" ]; then
  pending_local_update=1
fi

if version_ge "$committed_version" "$latest_version" && [ "$pending_local_update" -eq 0 ]; then
  echo "No newer stable Chromium version found; exiting."
  exit 0
fi

if [ "$pending_local_update" -eq 1 ]; then
  echo "Working tree already has a pending version bump; completing that update."
fi

command -v claude >/dev/null

cd "$alacrium_dir"

target_version="$(printf '%s\n%s\n' "$working_version" "$latest_version" | sort -V | tail -n1)"
build_log="${state_dir}/build-${target_version}.log"
deb_file="${alacrium_dir}/chromium/src/out/alacrium/alacrium-browser_${target_version}_AVX.deb"

agent_args=(
  claude -p
  --model claude-sonnet-5-5
  --effort high
  --dangerously-skip-permissions
  --add-dir "$aur_src_dir"
  --add-dir "$aur_bin_dir"
)

if [ "${ALACRIUM_UPDATER_DRY_RUN:-}" = 1 ]; then
  printf 'Updater would run:'
  printf ' %q' "${agent_args[@]}"
  printf ' <prompt>\n'
  exit 0
fi

preflight="$(
cat <<PREFLIGHT
Preflight:
- Committed Alacrium version: ${committed_version}
- Working-tree Alacrium version: ${working_version}
- Latest Chromium stable Linux version: ${latest_version}
- Target update version: ${target_version}

You are running as a daily unattended Alacrium updater for Braulio Oliveira.
The wrapper script drives the phases and runs the long build itself; do the
phase below and nothing else.

Local paths:
- Alacrium repo: the current working directory supplied by the wrapper
- Source AUR repo: aur/alacrium-browser
- Binary AUR repo: aur/alacrium-browser-bin

Rules:
- Keep all changes reproducible in git.
- Do not use destructive git commands.
- Do not change unrelated files.
- Do not push if validation fails.
- Use git author/committer: Braulio Oliveira <brauliobo@gmail.com>.
- Work only on main. Start from the already fast-forwarded main checkout; do
  not create or use an automation branch.
- Use concise commit messages.
PREFLIGHT
)"

prepare_prompt="$(
cat <<'PROMPT'

Phase: prepare the source for the target version. Do NOT build, commit or push.
- The working-tree version.sh already naming the target is an incomplete
  previous run; still verify and finish it.
- Run the existing repo tooling (skip rebase_to only when the Chromium checkout
  is already synced to the target tag):
  ./infra/rebase_to.sh <target version>
  ./infra/rebase_check.sh --with-upstream
- If patches need mechanical porting, update the patch/tool inputs rather than
  editing Chromium output by hand.
- Leave no *.rej files under chromium/src.
- Final response: whether the source is ready to build, or the blocker.
PROMPT
)"

publish_prompt="$(
cat <<'PROMPT'

Phase: publish. The wrapper already built the DEB and RPM in
chromium/src/out/alacrium for the target version. Do NOT rebuild.

Alacrium:
- Commit the validated update (version.sh, upstream_version.sh, and the
  patch/tool inputs changed by the update, staging files individually) directly
  to main and push main.

Local install:
- Build an Arch package from the generated DEB using aur/alacrium-browser-bin.
- Install locally with pacman using sudo when available. Prefer sudo -n; if sudo
  requires a password and cannot prompt, leave the built package path and report
  that install was skipped.

Release and AUR:
- Upload the version-matched DEB, RPM, and final
  alacrium-browser-bin-<version>-<pkgrel>-x86_64.pkg.tar.zst to the GitHub
  release tag M<version> before publishing AUR metadata.
- Update aur/alacrium-browser:
  - pkgver/pkgrel
  - pinned Alacrium git commit
  - package from the generated DEB data.tar.xz payload without RPM tooling
  - .SRCINFO
- Update aur/alacrium-browser-bin:
  - pkgver/pkgrel
  - pinned Alacrium git commit
  - version-matched GitHub release DEB URL and sha256sum
  - extract data.tar.xz with bsdtar; do not add rpm-tools or RPM dependencies
  - .SRCINFO
- Commit and push each AUR repo to AUR.

Validation before pushing:
- makepkg --printsrcinfo works in each AUR repo.
- The DEB source and Arch binary release asset URLs are reachable and their
  downloaded SHA-256 checksums match the local artifacts.
- AUR git remotes are reachable using the configured SSH askpass.

Final response: state version checked, main commit pushed, AUR package commits
pushed, local install result, and any blocker.
PROMPT
)"

run_agent() {
  printf '%s\n%s\n' "$preflight" "$1" | "${agent_args[@]}" | tee "$last_message"
}

run_agent "$prepare_prompt"

./infra/rebase_check.sh
if [ -n "$(find "${alacrium_dir}/chromium/src" -name '*.rej' -print -quit)" ]; then
  echo "Leftover .rej files after preparing the source; aborting." >&2
  exit 1
fi

echo "$(date -Is) building ${target_version}; log: ${build_log}"
nice -n 10 ionice -c2 -n7 ./build_incremental.sh 6 --packages > "$build_log" 2>&1
test -f "$deb_file"

run_agent "$publish_prompt"
echo "$(date -Is) finished Alacrium updater"
