#!/usr/bin/env bash
# tmux-annotations — annotate copy-mode selections, collect them later.
#
#   copy mode:  <selection> + i   → attach a note to the selection
#   prefix + a                    → toggle the annotations overlay
#   prefix + Y  (or Y in overlay) → copy all annotations as markdown & clear
#
# Options (set -g in tmux.conf before loading):
#   @annotations-key        annotate key in copy mode    (default: i)
#   @annotations-view-key   toggle overlay, prefix table (default: a)
#   @annotations-copy-key   copy-all key, prefix table   (default: Y)
#   @annotations-dir        data directory (default: ~/.local/share/tmux-annotations)
set -u
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$CURRENT_DIR/scripts/helpers.sh"

get_opt() {
  local v
  v="$(tmux show-option -gqv "$1")"
  printf '%s' "${v:-$2}"
}

key_annotate="$(get_opt @annotations-key i)"
key_view="$(get_opt @annotations-view-key a)"
key_copy="$(get_opt @annotations-copy-key Y)"

if ! tmux_at_least 3 2; then
  # No display-popup before 3.2 — bind the keys to a clear explanation
  # instead of letting the scripts fail cryptically.
  msg='tmux-annotations needs tmux 3.2+ (display-popup)'
  tmux bind-key -T copy-mode-vi "$key_annotate" display-message "$msg"
  tmux bind-key -T copy-mode "$key_annotate" display-message "$msg"
  tmux bind-key "$key_view" display-message "$msg"
  tmux bind-key "$key_copy" display-message "$msg"
  exit 0
fi

# Cache the popup-capability tier so the hot path never re-runs tmux -V.
if tmux_at_least 3 3; then
  tmux set-option -g @annotations-caps 33
else
  tmux set-option -g @annotations-caps 32
fi

tmux bind-key -T copy-mode-vi "$key_annotate" run-shell -b "'$CURRENT_DIR/scripts/annotate.sh'"
tmux bind-key -T copy-mode "$key_annotate" run-shell -b "'$CURRENT_DIR/scripts/annotate.sh'"
tmux bind-key "$key_view" run-shell -b "'$CURRENT_DIR/scripts/view.sh'"
tmux bind-key "$key_copy" run-shell -b "'$CURRENT_DIR/scripts/copy.sh'"
