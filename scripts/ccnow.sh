#!/usr/bin/env bash
# ccnow — Print the currently-active provider.
# Exit code: 0 if set, 1 if not set.
# Part of ccpod

set -euo pipefail

SCRIPT_DIR="$(
  src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
)"

source "$SCRIPT_DIR/lib/common.sh"

mode="plain"
case "${1:-}" in
  --badge|-b) mode="badge" ;;
  --help|-h)
    cat <<'EOF'
ccnow — 打印当前 provider

USAGE
  ccnow            Print plain provider name (e.g. "official")
  ccnow --badge    Print formatted badge (e.g. "🟢 official")
  ccnow --help     Show this help
EOF
    exit 0
    ;;
  "") ;;
  *) echo "未知参数: $1" >&2; exit 2 ;;
esac

if [[ ! -f "$CCPOD_CURRENT_FILE" ]]; then
  echo "unset"
  exit 1
fi

name="$(cat "$CCPOD_CURRENT_FILE")"
if [[ "$mode" == "badge" ]]; then
  ccpod_format_badge "$name"
  echo
else
  echo "$name"
fi
