#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/preflight-import-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -parse-as-library "$repo/menubar/Sources/CCPodMenuBar/ProviderImportPreflight.swift" \
  "$repo/menubar/Sources/CCPodMenuBar/SecretResolver.swift" \
  "$repo/scripts/tests/preflight_import.swift" -o "$scratch/check"
"$scratch/check"
