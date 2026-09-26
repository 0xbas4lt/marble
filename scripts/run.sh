#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

exec qemu-system-x86_64 \
    -M q35 -m 256M \
    -cdrom build/marble.iso \
    -serial stdio \
    -no-reboot -no-shutdown \
    "$@"
