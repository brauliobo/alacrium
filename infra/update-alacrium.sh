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

# Log from inside the script so a missing state dir can't break a cron redirect.
if [ "${ALACRIUM_UPDATER_LOG:-1}" = 1 ]; then
  exec >> "${state_dir}/cron.log" 2>&1
fi

export PATH="/home/braulio/.local/bin:/home/braulio/bin:/usr/local/bin:/usr/bin:/bin"
for depot_tools in "${DEPOT_TOOLS_DIR:-}" "$HOME/depot_tools" "$HOME/Projects/depot_tools"; do
  if [ -n "$depot_tools" ] && [ -x "$depot_tools/gclient" ]; then
    export PATH="$depot_tools:$PATH"
    break
  fi
done
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

command -v t3 >/dev/null

active_thread="$(
  t3 thread list --project "$alacrium_dir" --json 2>/dev/null | python3 -c '
import json, sys

active = {"preparing", "queued", "starting", "running", "waiting"}
for thread in json.load(sys.stdin):
    title = thread.get("title", "")
    if title.startswith("Update Alacrium") and thread.get("status") in active:
        print(f"{thread.get(\"threadId\")} ({thread.get(\"status\")})")
        break
'
)"

if [ -n "$active_thread" ]; then
  echo "An Alacrium updater thread is already active ($active_thread); exiting."
  exit 0
fi

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

cd "$alacrium_dir"

target_version="$(printf '%s\n%s\n' "$working_version" "$latest_version" | sort -V | tail -n1)"
build_log="${state_dir}/build-${target_version}.log"
deb_file="${alacrium_dir}/chromium/src/out/alacrium/alacrium-browser_${target_version}_AVX.deb"

thread_title="Update Alacrium ${target_version}"
use_cli_option=0
if t3 thread start --help 2>/dev/null | grep -q -- '--option'; then
  use_cli_option=1
fi

agent_args=(
  t3 thread start
  --title "$thread_title"
  --provider antigravity
  --model gemini-4-hydrogen
  --option thought_level=high
  --json
  "$alacrium_dir"
  -
)

if [ "${ALACRIUM_UPDATER_DRY_RUN:-}" = 1 ]; then
  if [ "$use_cli_option" -eq 1 ]; then
    printf 'Updater would run:'
    printf ' %q' "${agent_args[@]}"
    printf ' <prompt>\n'
  else
    printf 'Updater would launch T3 thread via t3_thread_launch (provider=antigravity, model=gemini-4-hydrogen, options=[thought_level=high], project=%q, title=%q)\n' "$alacrium_dir" "$thread_title"
  fi
  exit 0
fi

prompt="$(
cat <<PROMPT
Preflight:
- Committed Alacrium version: ${committed_version}
- Working-tree Alacrium version: ${working_version}
- Latest Chromium stable Linux version: ${latest_version}
- Target update version: ${target_version}

You are running as a daily unattended Alacrium updater for Braulio Oliveira inside a T3 Code thread on bhavapower.lan.
Complete all phases below in order.

Local paths:
- Alacrium repo: ${alacrium_dir}
- Source AUR repo: ${aur_src_dir}
- Binary AUR repo: ${aur_bin_dir}
- Build log: ${build_log}
- Expected DEB output: ${deb_file}

Environment:
- Before running git, gh, AUR, or Chromium tooling commands, load the updater environment and ensure depot_tools is on PATH:
  set -a; [ -f /home/braulio/.config/alacrium-updater/env ] && . /home/braulio/.config/alacrium-updater/env; set +a
  for d in "\${DEPOT_TOOLS_DIR:-}" "\$HOME/depot_tools" "\$HOME/Projects/depot_tools"; do
    [ -n "\$d" ] && [ -x "\$d/gclient" ] && export PATH="\$d:\$PATH" && break
  done

Rules:
- Keep all changes reproducible in git.
- Do not use destructive git commands.
- Do not change unrelated files.
- Do not push if validation fails.
- Use git author/committer: Braulio Oliveira <brauliobo@gmail.com>.
- Work only on main. Start from the already fast-forwarded main checkout; do not create or use an automation branch.
- Use concise commit messages.

Phase 1 — Prepare the source for ${target_version} (do NOT commit or push yet):
- A working-tree version.sh already naming ${target_version} is an incomplete previous run; still verify and finish it.
- Run the existing repo tooling (skip rebase_to only when the Chromium checkout is already synced to the target tag):
  ./infra/rebase_to.sh ${target_version}
  ./infra/rebase_check.sh --with-upstream
- If patches need mechanical porting, update the patch/tool inputs rather than editing Chromium output by hand.
- Leave no *.rej files under chromium/src.

Phase 2 — Validate and build:
- Run ./infra/rebase_check.sh and verify find "${alacrium_dir}/chromium/src" -name '*.rej' -print -quit returns nothing. If any .rej file remains or rebase_check fails, stop and report the blocker without building or pushing.
- Run the incremental build:
  nice -n 10 ionice -c2 -n7 ./build_incremental.sh 6 --packages > "${build_log}" 2>&1
- Verify "${deb_file}" exists. If the build fails, stop and report the blocker (and tail of ${build_log}) without committing or pushing.

Phase 3 — Publish (do NOT rebuild):
Alacrium:
- Commit the validated update (version.sh, upstream_version.sh, and the patch/tool inputs changed by the update, staging files individually) directly to main and push main.

Local install:
- Build an Arch package from the generated DEB using aur/alacrium-browser-bin.
- Install locally with pacman using sudo when available. Prefer sudo -n; if sudo requires a password and cannot prompt, leave the built package path and report that install was skipped.

Release and AUR:
- Upload the version-matched DEB, RPM, and final alacrium-browser-bin-<version>-<pkgrel>-x86_64.pkg.tar.zst to the GitHub release tag M<version> before publishing AUR metadata.
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
- The DEB source and Arch binary release asset URLs are reachable and their downloaded SHA-256 checksums match the local artifacts.
- AUR git remotes are reachable using the configured SSH relay/askpass.

Final response: state version checked, build result, main commit pushed, AUR package commits pushed, local install result, and any blocker.
PROMPT
)"

if [ "$use_cli_option" -eq 1 ]; then
  launch_json="$(printf '%s\n' "$prompt" | "${agent_args[@]}")"
else
  launch_helper="$(mktemp /tmp/alacrium-t3-launch-XXXXXX.mjs)"
  cleanup_launch_helper() {
    rm -f "$launch_helper"
  }
  trap cleanup_launch_helper EXIT
  cat > "$launch_helper" <<'NODE'
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import * as fs from "node:fs";

const req = createRequire("/srv/t3code/apps/server/src/bin.ts");
const Effect = await import(pathToFileURL(req.resolve("effect/Effect")).href);
const Layer = await import(pathToFileURL(req.resolve("effect/Layer")).href);
const References = await import(pathToFileURL(req.resolve("effect/References")).href);
const Option = await import(pathToFileURL(req.resolve("effect/Option")).href);
const NodeServices = await import(pathToFileURL(req.resolve("@effect/platform-node/NodeServices")).href);
const NodeCrypto = await import(pathToFileURL(req.resolve("@effect/platform-node/NodeCrypto")).href);
const NetService = await import("/srv/t3code/packages/shared/src/Net.ts");
const EnvironmentAuth = await import("/srv/t3code/apps/server/src/auth/EnvironmentAuth.ts");
const ServerConfig = await import("/srv/t3code/apps/server/src/config.ts");
const { resolveCliAuthConfig } = await import("/srv/t3code/apps/server/src/cli/config.ts");
const { mcpToolSession } = await import("/srv/t3code/apps/server/src/mcp/AcpMcpStdioBridge.ts");
const { readLiveServerRuntimeState } = await import("/srv/t3code/apps/server/src/serverRuntimeState.ts");

const [projectPath, title] = process.argv.slice(2);
const message = fs.readFileSync(0, "utf8");
const baseDir = process.env.T3CODE_HOME || `${process.env.HOME}/.t3`;

const program = Effect.gen(function* () {
  const config = yield* resolveCliAuthConfig({ baseDir: Option.some(baseDir), json: true }, "Error", { quietLogs: true });
  const rt = yield* readLiveServerRuntimeState(config.serverRuntimeStatePath);
  if (Option.isNone(rt)) throw new Error("T3 Code server is not running");
  const origin = rt.value.origin;
  return yield* Effect.gen(function* () {
    const auth = yield* EnvironmentAuth.EnvironmentAuth;
    const issued = yield* Effect.acquireRelease(
      auth.issueMcpClientSession({ label: "alacrium-updater", access: "full-access", peerLink: false, client: { deviceType: "bot" } }),
      (s) => auth.revokeSession(s.sessionId).pipe(Effect.ignore({ log: true })),
    );
    const session = yield* mcpToolSession({
      endpoint: new URL("/mcp", origin).href,
      authorization: `Bearer ${issued.token}`,
      clientName: "alacrium-updater",
    });
    const projects = [];
    let cursor = 0;
    while (cursor !== null) {
      const listRes = yield* session.call("t3_project_list", { cursor, limit: 100 });
      projects.push(...(listRes.structuredContent?.projects ?? []));
      cursor = listRes.structuredContent?.nextCursor ?? null;
    }
    const realTarget = fs.realpathSync(projectPath);
    const project = projects.find((p) => {
      try {
        return fs.realpathSync(p.workspaceRoot) === realTarget;
      } catch {
        return p.workspaceRoot === projectPath;
      }
    });
    if (!project) throw new Error(`T3 project not found for ${projectPath}`);
    const launchRes = yield* session.call("t3_thread_launch", {
      projectId: project.id,
      title,
      message,
      modelSelection: {
        instanceId: "antigravity",
        model: "gemini-4-hydrogen",
        options: [{ id: "thought_level", value: "high" }],
      },
    });
    if (launchRes.isError) {
      throw new Error(JSON.stringify(launchRes.content ?? launchRes));
    }
    console.log(JSON.stringify(launchRes.structuredContent));
  }).pipe(
    Effect.scoped,
    Effect.provide(
      EnvironmentAuth.layerRuntime.pipe(
        Layer.provide(ServerConfig.layer(config)),
        Layer.provide(Layer.succeed(References.MinimumLogLevel, "Error")),
      ),
    ),
  );
}).pipe(
  Effect.provideService(References.MinimumLogLevel, "Error"),
  Effect.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer, NetService.layer)),
);

await Effect.runPromise(program);
NODE
  launch_json="$(printf '%s\n' "$prompt" | node "$launch_helper" "$alacrium_dir" "$thread_title")"
fi
echo "$(date -Is) started Alacrium updater T3 thread: ${launch_json}"
