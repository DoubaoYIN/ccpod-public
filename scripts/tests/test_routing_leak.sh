#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/routing-leak-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/RoutingLeakPolicy.swift" \
  "$repo/scripts/tests/routing_leak.swift" -o "$scratch/check"
"$scratch/check"
