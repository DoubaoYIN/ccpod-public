#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/preflight-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/LinePreflight.swift" \
  "$repo/scripts/tests/preflight.swift" -o "$scratch/check"
"$scratch/check"
