#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/popover-click-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
src="$repo/menubar/Sources/CCPodMenuBar"
swiftc "$src/PopoverClickClassifier.swift" "$repo/scripts/tests/popover_click.swift" -o "$scratch/check"
"$scratch/check"
