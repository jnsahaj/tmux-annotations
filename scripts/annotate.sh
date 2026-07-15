#!/usr/bin/env bash
# Bound to the annotate key in copy mode. Stages the current selection,
# then opens the floating input popup to attach a note to it.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

PANE="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}')}"

if [ "$(tmux display-message -p -t "$PANE" '#{selection_present}')" != "1" ]; then
  tmux display-message 'annotations: select some text first (v / Space to start a selection)'
  exit 0
fi

: > "$STAGE"
tmux send-keys -t "$PANE" -X copy-pipe "cat > '$STAGE'"
tmux send-keys -t "$PANE" -X clear-selection

# copy-pipe writes asynchronously — wait briefly for the selection to land.
tries=0
while [ "$tries" -lt 40 ]; do
  [ -s "$STAGE" ] && break
  sleep 0.05
  tries=$((tries + 1))
done
if ! [ -s "$STAGE" ]; then
  tmux display-message 'annotations: could not read selection'
  exit 0
fi

open_popup 66 10 ' New Annotation ' "'$DIR/add.sh'"
