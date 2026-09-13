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
export GIT_ASKPASS="$SSH_ASKPASS"
export GIT_SSH_COMMAND="ssh -i /home/braulio/.ssh/id_github -o IdentitiesOnly=yes"

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

command -v cursor-agent >/dev/null

agent_args=(
  cursor-agent
  -p
  --force
  --trust
  --sandbox disabled
  --approve-mcps
  --workspace "$alacrium_dir"
  --add-dir "$aur_src_dir"
  --add-dir "$aur_bin_dir"
  --output-format text
)

if [ "${ALACRIUM_UPDATER_DRY_RUN:-}" = 1 ]; then
  printf 'Updater would run:'
  printf ' %q' "${agent_args[@]}"
  printf ' <prompt>\n'
  exit 0
fi

prompt="$(
cat <<PROMPT
Preflight:
- Committed Alacrium version: ${committed_version}
- Working-tree Alacrium version: ${working_version}
- Latest Chromium stable Linux version: ${latest_version}
- Target update version: ${latest_version}

PROMPT
cat <<'PROMPT'
You are running as a daily unattended Alacrium updater for Braulio Oliveira.

Goal:
- Check whether a newer stable Chromium exists than the committed version in
  `version.sh` on origin/main.
- The wrapper already detected that either a newer stable Linux release exists
  or the working tree has a pending uncommitted bump. Use the preflight target
  version above unless official/current sources show a newer stable.
- Do not skip just because the working-tree `version.sh` already names the
  target. That is an incomplete previous run and must be finished.
- If no newer stable exists and there is no pending local bump, make no repo
  changes and exit clearly.
- If a newer minor or major stable exists, or a pending bump must be finished,
  update Alacrium, build/package it with low priority and 6 jobs, install it
  locally, push main, update both AUR packages, and push them.

Local paths:
- Alacrium repo: the current working directory supplied by the wrapper
- Source AUR repo: aur/alacrium-browser
- Binary AUR repo: aur/alacrium-browser-bin

Rules:
- Use official/current sources to determine the latest stable Chromium version.
- Keep all changes reproducible in git.
- Do not use destructive git commands.
- Do not change unrelated files.
- Do not push if validation fails.
- Use git author/committer: Braulio Oliveira <brauliobo@gmail.com>.
- Work only on main. Start from the already fast-forwarded main checkout; do
  not create or use an automation branch.
- Use concise commit messages.

Alacrium update flow:
- Fetch origin/upstream/chromium as needed.
- Commit the validated update directly to main and push main.
- Run the existing repo tooling first:
  ./infra/rebase_to.sh <version>
  ./infra/rebase_check.sh --with-upstream
- If patches need mechanical porting, update the patch/tool inputs rather than editing Chromium output by hand.
- Preserve the incremental build strategy and build with:
  nice -n 10 ionice -c2 -n7 ./build_incremental.sh 6 --packages
- Reuse the existing Chromium checkout and out/alacrium.

Local install:
- Build an Arch package from the generated DEB using aur/alacrium-browser-bin.
- Install locally with pacman using sudo when available. Prefer sudo -n; if sudo requires a password and cannot prompt, leave the built package path and report that install was skipped.

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
- ./infra/rebase_check.sh
- makepkg --printsrcinfo works in each AUR repo.
- The DEB source and Arch binary release asset URLs are reachable and their
  downloaded SHA-256 checksums match the local artifacts.
- AUR git remotes are reachable using the configured SSH askpass.

Final response:
- State version checked, whether an update was done, main commit pushed, AUR package commits pushed, local install result, and any blocker.
PROMPT
)"

"${agent_args[@]}" "$prompt" | tee "$last_message"
echo "$(date -Is) finished Alacrium updater"
