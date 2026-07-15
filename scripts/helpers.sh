# shellcheck shell=bash
# Shared helpers — sourced by every script.

_opt_dir="$(tmux show-option -gqv @annotations-dir 2>/dev/null || true)"
DATA_DIR="${_opt_dir:-$HOME/.local/share/tmux-annotations}"
NOTES_DIR="$DATA_DIR/notes"
# shellcheck disable=SC2034  # used by the sourcing scripts
STAGE="$DATA_DIR/.stage"
mkdir -p "$NOTES_DIR"

# Resolve a configured key, for hints in messages.
opt_key() {
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  printf '%s' "${v:-$2}"
}

# Is the running tmux at least version $1.$2? Handles "3.5a",
# "next-3.6", "3.3-rc" etc.
tmux_at_least() {
  local v maj min
  v="$(tmux -V 2>/dev/null | sed 's/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')"
  case "$v" in
    [0-9]*.[0-9]*) ;;
    *) v=999.0 ;;   # unparsable ("tmux master") — assume modern
  esac
  maj="${v%%.*}"
  min="${v#*.}"; min="${min%%[!0-9]*}"
  [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
}

# Does the locale speak UTF-8? Drives glyph fallbacks.
has_utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) return 0 ;;
    *) return 1 ;;
  esac
}

# Open a styled popup, degrading gracefully: border/style/title flags
# need tmux >= 3.3; size is clamped to the client so small terminals
# don't reject it.  $1 w, $2 h, $3 title, $4 command
open_popup() {
  local w=$1 h=$2 cw ch
  cw="$(tmux display-message -p '#{client_width}' 2>/dev/null || true)"
  ch="$(tmux display-message -p '#{client_height}' 2>/dev/null || true)"
  case "$cw" in '' | *[!0-9]*) cw=0 ;; esac
  case "$ch" in '' | *[!0-9]*) ch=0 ;; esac
  [ "$cw" -gt 8 ] && [ "$w" -gt $((cw - 2)) ] && w=$((cw - 2))
  [ "$ch" -gt 8 ] && [ "$h" -gt $((ch - 2)) ] && h=$((ch - 2))
  if tmux_at_least 3 3; then
    tmux display-popup -w "$w" -h "$h" -b rounded -S 'fg=colour221' -T "$3" -E "$4"
  else
    tmux display-popup -w "$w" -h "$h" -E "$4"
  fi
}

# List note files oldest-first (filenames start with epoch seconds).
list_notes() {
  # shellcheck disable=SC2012  # filenames are ours: epoch-rand.note
  ls "$NOTES_DIR"/*.note 2>/dev/null | sort
}

note_count() {
  list_notes | wc -l | tr -d ' '
}

# Notes may be multiline but are stored on line 1 of the note file —
# newlines and backslashes are escaped on save, undone on read.
esc_note() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

unesc_note() {
  printf '%b' "$1"
}

# Epoch → "Jul 15 14:32" (BSD date first, GNU fallback).
fmt_time() {
  date -r "$1" '+%b %d %H:%M' 2>/dev/null || date -d "@$1" '+%b %d %H:%M'
}

# stdin → system clipboard: macOS, Wayland, X11, WSL — first tool that
# works wins. Always lands in the tmux buffer too; load-buffer -w asks
# the outer terminal via OSC 52, which covers SSH sessions.
clip_copy() {
  local tmpf
  tmpf="$(mktemp)"
  cat > "$tmpf"
  if command -v pbcopy >/dev/null 2>&1 && pbcopy < "$tmpf" 2>/dev/null; then
    :
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1 && wl-copy < "$tmpf" 2>/dev/null; then
    :
  elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1 && xclip -selection clipboard < "$tmpf" 2>/dev/null; then
    :
  elif [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1 && xsel -i -b < "$tmpf" 2>/dev/null; then
    :
  elif command -v clip.exe >/dev/null 2>&1 && clip.exe < "$tmpf" 2>/dev/null; then
    :
  fi
  tmux load-buffer -w "$tmpf" 2>/dev/null || tmux load-buffer "$tmpf" 2>/dev/null || true
  rm -f "$tmpf"
}

# Render all notes as markdown: "## note (time)" + "> selection" blocks.
# A multiline note becomes heading (first line) + paragraph (the rest).
notes_as_markdown() {
  local f base epoch note head rest first=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    epoch="${base%%-*}"
    note="$(unesc_note "$(head -n 1 "$f")")"
    head="${note%%$'\n'*}"
    rest=''
    [ "$note" != "$head" ] && rest="${note#*$'\n'}"
    [ "$first" = 1 ] || printf '\n'
    first=0
    printf '## %s  (%s)\n' "$head" "$(fmt_time "$epoch")"
    [ -n "$rest" ] && printf '\n%s\n' "$rest"
    printf '\n'
    tail -n +2 "$f" | sed 's/^/> /'
  done < <(list_notes)
}
