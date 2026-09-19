# AGENTS.md

Essential instructions for coding agents working on this Alacrium repo.

## Repo Model

This is not a full Chromium checkout. It is an Alacrium overlay and patch set
applied onto Chromium at the repository-local `chromium/src` checkout.
Chromium is expected to be a git/gclient checkout from
`https://chromium.googlesource.com/chromium/src.git`, not a release tarball.

- `src/<path>` overlays `$CR_SRC_DIR/<path>`.
- `other/*.patch` contains replayable Chromium/V8/FFmpeg patches.
- `infra/*` contains tooling, packaging helpers, and generated-input helpers.
- Chromium version is pinned by `ALACRIUM_VER` in `version.sh` and `CR_VER` in
  `upstream_version.sh`.

## Canonical Workflow

```bash
./trunk.sh
./version.sh
./setup.sh [flavour]
./build.sh <jobs>
```

For local incremental Linux rebuilds, prefer:

```bash
./build_incremental.sh 6
./build_incremental.sh 6 --packages
```

It keeps `out/alacrium`, uses `nice`/`ionice`, disables unnecessary full rebuilds,
and limits builds to 6 jobs by default.

For a version bump, use:

```bash
./infra/rebase_to.sh <chromium-tag>
```

It updates the pinned versions, syncs Chromium, applies the overlay, writes the
upstream diff report, and stops before building.

## Current Rebase Rules

- Chromium target for this PR is `153.0.8010.52`.
- Do not restore the old JPEG XL overlay; Chromium M147+ has native JPEG XL build
  integration via `enable_jxl_decoder`.
- Keep Chrome/Chromium source changes reproducible through `src/`, `other/`,
  or `infra/` tooling. Do not rely on manual edits inside `$CR_SRC_DIR`.
- `setup.sh` patching must stay idempotent. Per-patch apply/check/skip logic is
  required; do not reintroduce one global sentinel file for all patches.
- Generated Alacrium translation additions live under the inherited
  `src/chrome/app/resources/alacrium_additions/` source path and are merged by
  `infra/merge_alacrium_xtb.py`, replacing the old huge translate patch.
- API keys stay outside git in `API_KEYS.txt`; regenerate
  `other/google-api-keys-defaults.patch` with
  `infra/generate_google_api_keys_patch.sh --input API_KEYS.txt --output other/google-api-keys-defaults.patch`
  when keys change.
- Windows-only patches may stay disabled until Linux is green, but keep them
  named clearly as disabled/deferred.
- History SQL patches must not use SQLite window functions; Chromium builds
  SQLite with `SQLITE_OMIT_WINDOWFUNC`, and invalid History SQL can raze DBs.

## AUR Releases

- The canonical AUR repositories are `aur/alacrium-browser` and
  `aur/alacrium-browser-bin`. They are independent Git repositories;
  do not use `/home/braulio/Projects/aur/`.
- The source package must pin an Alacrium commit that has been pushed to
  `github.com/brauliobo/alacrium`.
- Build the binary package from the version-matched RPM, then upload
  `alacrium-browser-bin-<version>-<pkgrel>-x86_64.pkg.tar.zst` to the
  GitHub release tag `M<version>` before publishing the binary AUR
  package.
- Update `PKGBUILD` and regenerate `.SRCINFO` with `makepkg --printsrcinfo >
  .SRCINFO` in each AUR repository. Stage only those files; do not stage build
  archives, `src/`, `pkg/`, `alacrium/`, or `depot_tools/` caches.
- Verify the binary package SHA-256 and release asset URL before committing or
  pushing the binary AUR package.

## Editing Rules

- Do not run `git add -A`.
- Do not commit unless the user explicitly asks for a commit.
- Keep large build artifacts, packages, Chromium checkouts, and worktree output
  out of git.
- Prefer deleting obsolete overlays/patches when upstream already carries the
  behavior.
- Keep `args.gn` host-neutral and resolve checkout-relative paths from
  `chromium/src`.

## Validation

Before considering a PR branch ready:

```bash
./infra/rebase_check.sh
./setup.sh
find "$CR_SRC_DIR" -name '*.rej' -print
./build_incremental.sh 6
./build_incremental.sh 6 --packages
```

Smoke checks:

- `alacrium-browser --version` reports the pinned Alacrium version.
- `navigator.globalPrivacyControl` is `true`.
- Chrome sync is available when Alacrium API keys are present.
- Installed package permissions are standard, especially `chrome-sandbox`
  owned by root with mode `4755`.
