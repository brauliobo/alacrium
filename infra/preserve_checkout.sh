#!/bin/bash
# Preserve generated checkout changes without discarding tracked or new files.
set -euo pipefail

log="$1"
checkout="$(git rev-parse --show-toplevel)"
[ -n "$(git status --porcelain --untracked-files=normal)" ] || exit 0

git stash push --include-untracked --message "alacrium upstream update $(date -u +%Y-%m-%dT%H:%M:%SZ)"
ref="$(git rev-parse refs/stash)"
printf '%s\t%s\n' "$checkout" "$ref" >> "$log"
printf 'Preserved checkout changes: %s %s (recorded in %s)\n' "$checkout" "$ref" "$log"
