#!/usr/bin/env bash
# Copy ALL annotations to the clipboard as markdown, then remove them.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

count="$(note_count)"
if [ "$count" -eq 0 ]; then
  tmux display-message 'annotations: nothing to copy'
  exit 0
fi

notes_as_markdown | clip_copy
rm -f "$NOTES_DIR"/*.note

tmux display-message "annotations: $count copied to clipboard & cleared"
