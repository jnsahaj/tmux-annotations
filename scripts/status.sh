#!/usr/bin/env bash
# Status-line segment: prints the annotation count when any exist,
# nothing otherwise. Run by tmux via #() every status-interval.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

n="$(note_count)"
[ "$n" -gt 0 ] || exit 0
if has_utf8; then
  printf '✎ %s ' "$n"
else
  printf '* %s ' "$n"
fi
