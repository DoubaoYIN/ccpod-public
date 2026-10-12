#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/launch-options-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
src="$repo/menubar/Sources/CCPodMenuBar"
swiftc "$src/ProviderName.swift" "$src/ProviderService.swift" \
  "$src/GatewayLineService.swift" "$src/ProviderImportService.swift" \
  "$src/LaunchOptions.swift" \
  "$repo/scripts/tests/launch_options.swift" -o "$scratch/check"
"$scratch/check"
