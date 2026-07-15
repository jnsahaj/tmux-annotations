#!/usr/bin/env bash
# Runs inside the input popup: shows a preview of the staged selection,
# reads a one-line note, saves both as a note file.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/helpers.sh"

[ -s "$STAGE" ] || exit 0
sel="$(cat "$STAGE")"
nlines="$(printf '%s\n' "$sel" | wc -l | tr -d ' ')"

printf '\n'
printf '\033[2m'
printf '%s\n' "$sel" | head -n 3 | cut -c1-58 | sed 's/^/   │ /'
[ "$nlines" -gt 3 ] && printf '   │ … %s more lines\n' "$((nlines - 3))"
printf '\033[0m\n'
printf '   \033[1;33mnote ›\033[0m '

IFS= read -e -r note || exit 0
note="$(printf '%s' "$note" | tr -d '\n')"
[ -n "$note" ] || exit 0

file="$NOTES_DIR/$(date +%s)-$RANDOM.note"
{
  printf '%s\n' "$note"
  printf '%s\n' "$sel"
} > "$file"
rm -f "$STAGE"

tmux display-message "annotations: saved — $(note_count) total. prefix+$(opt_key @annotations-view-key a) to view"
