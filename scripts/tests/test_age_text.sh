#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/age-text-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/AgeText.swift" \
  "$repo/scripts/tests/age_text.swift" -o "$scratch/check"
"$scratch/check"
