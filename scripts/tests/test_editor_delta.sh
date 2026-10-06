#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/editor-delta-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -parse-as-library "$repo/menubar/Sources/CCPodMenuBar/EditorDelta.swift" \
  "$repo/scripts/tests/editor_delta.swift" -o "$scratch/check"
"$scratch/check"
