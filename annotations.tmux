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

# ── status-line indicator (tmux 3.4+ ranges; @annotations-status off
# disables). Shows a count while annotations exist; clicking it opens
# the viewer. The mouse binding is only installed when MouseDown1Status
# still has its default action, so customized setups are left alone.
if [ "$(get_opt @annotations-status on)" = on ] && tmux_at_least 3 4; then
  seg="#[range=user|annotations]#($CURRENT_DIR/scripts/status.sh)#[norange]"
  sr="$(tmux show-option -gv status-right 2>/dev/null || true)"
  case "$sr" in
    *'range=user|annotations'*) ;;
    *) tmux set-option -g status-right "$seg$sr" ;;
  esac
  mb="$(tmux list-keys -T root MouseDown1Status 2>/dev/null || true)"
  case "$mb" in
    '' | *select-window* | *annotations*)
      tmux bind-key -T root MouseDown1Status if-shell -F \
        '#{==:#{mouse_status_range},annotations}' \
        "run-shell -b \"'$CURRENT_DIR/scripts/view.sh'\"" \
        'select-window -t ='
      ;;
  esac
fi
