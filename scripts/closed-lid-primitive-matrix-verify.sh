#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "This script requires bash. Run it as: bash scripts/closed-lid-primitive-matrix-verify.sh ..." >&2
    exit 2
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/bag-mode-primitive-matrix-verify.sh" "$@"
