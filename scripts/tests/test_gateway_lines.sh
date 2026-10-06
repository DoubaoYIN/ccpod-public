#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/gateway-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
src="$repo/menubar/Sources/CCPodMenuBar"
swiftc "$src/ProviderName.swift" "$src/ProviderService.swift" \
  "$src/GatewayLineService.swift" "$src/ProviderImportService.swift" \
  "$repo/scripts/tests/gateway_lines.swift" -o "$scratch/check"
"$scratch/check" "$scratch"
