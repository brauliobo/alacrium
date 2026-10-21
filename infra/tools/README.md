# Alacrium Tools

This directory contains optional maintenance and reproduction helpers. The
canonical rebase/build flow remains documented in the repository root.

## Profiled Linux Build

Build a symbolized, profiling-friendly Alacrium output directory:

```bash
infra/tools/build_profiled_alacrium.sh 6
```

The script uses the repository-local `chromium/src` checkout. Set `OUT_DIR` to
use another output directory.

## CDP Process Dump

Dump process, target, performance, and `chrome://discards` state from a running
Alacrium instance with remote debugging enabled:

```bash
python -m pip install websockets
alacrium-browser --remote-debugging-port=9222
infra/tools/cdp_process_dump.py 9222 /tmp/alacrium-cdp-dump
```

## History Redirect Chain Repair

Detect repeated self-refresh visits that formed an unbounded client-redirect
chain. Alacrium must be completely closed so the History database can be locked:

```bash
infra/tools/repair_history_redirect_chains.py ~/.config/alacrium/Default/History
infra/tools/repair_history_redirect_chains.py --apply ~/.config/alacrium/Default/History
```

The first command is a dry run. `--apply` creates a timestamped backup before
marking the affected visits as redirect-chain starts; it does not delete visits.

Packages install the same tool, outside `PATH`, as
`/opt/alacrium-browser/tools/repair_history_redirect_chains.py`.

To also delete the self-refresh visits (keeping the newest visit of each day per
URL) and shrink the database, add `--delete-self-refresh`; it also takes a
backup and is a dry run without `--apply`:

```bash
infra/tools/repair_history_redirect_chains.py --delete-self-refresh --apply ~/.config/alacrium/Default/History
```

## NVIDIA VP9 Decode Stress

Stress Chromium's VP9 hardware decode path while collecting NVIDIA telemetry:

```bash
autoninja -C out/alacrium media/gpu/test:video_decode_accelerator_perf_tests
infra/tools/stress_nvidia_vp9_decode.sh
```

The script uses the repository-local `chromium/src` checkout and
`out/alacrium`. Set `OUT_DIR` to use another output directory.
