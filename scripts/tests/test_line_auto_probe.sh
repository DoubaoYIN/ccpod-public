#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/line-auto-probe-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/LineAutoProbePolicy.swift" \
  "$repo/scripts/tests/line_auto_probe.swift" -o "$scratch/check"
"$scratch/check"
