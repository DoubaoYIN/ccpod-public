#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$repo/scripts/tests/fixtures/model_onboard_catalog_20261005.json"
[[ -f "$fixture" ]] || { echo "FAIL 找不到夹具: $fixture"; exit 1; }
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/model-onboard-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/ModelOnboardPolicy.swift" \
  "$repo/scripts/tests/model_onboard.swift" -o "$scratch/check"
"$scratch/check" "$fixture"
