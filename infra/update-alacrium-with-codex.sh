#!/usr/bin/env bash
# Back-compat wrapper. Cron now uses update-alacrium-with-cursor-agent.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-alacrium-with-cursor-agent.sh" "$@"
