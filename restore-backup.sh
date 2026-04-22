#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper to run the installed restore tool.
#
# This exists so you can invoke restores from inside ~/lume-pi without
# memorizing the /usr/local/bin path.

exec /usr/local/bin/lume-restore-backup "$@"
