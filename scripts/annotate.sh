#!/usr/bin/env bash
# Bound to the annotate key in copy mode. Stages the current selection,
# then opens the floating input popup to attach a note to it.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

# Hot path: three tmux round-trips total. Everything queryable is
# batched into one display-message; copy-pipe and clear-selection share
# one client call; the popup opens IMMEDIATELY and add.sh waits for the
# async copy-pipe write in parallel with the popup drawing.
PANE="${TMUX_PANE:-}"
if [ -n "$PANE" ]; then
  info="$(tmux display-message -p -t "$PANE" '#{selection_present} #{client_width} #{client_height}')"
else
  info="$(tmux display-message -p '#{pane_id} #{selection_present} #{client_width} #{client_height}')"
  PANE="${info%% *}"
  info="${info#* }"
fi
selp="${info%% *}"
info="${info#* }"
cw="${info%% *}"
ch="${info##* }"

if [ "$selp" != "1" ]; then
  tmux display-message 'annotations: select some text first (v / Space to start a selection)'
  exit 0
fi

: > "$STAGE"
tmux send-keys -t "$PANE" -X copy-pipe "cat > '$STAGE'" \; send-keys -t "$PANE" -X clear-selection

open_popup 66 10 ' New Annotation ' "'$DIR/add.sh'" "$cw" "$ch"
