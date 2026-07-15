# shellcheck shell=bash
# Shared helpers — sourced by every script.

# All plugin options in ONE tmux round-trip — every tmux client call is
# a fork + socket round-trip (~10-20ms), and they add up to visible lag
# on the annotate hot path.
_annot_opts="$(tmux show-options -g 2>/dev/null | grep '^@annotations-' || true)"

annot_opt() { # $1 option name without the @annotations- prefix, $2 default
  local v
  case "$_annot_opts" in
    *"@annotations-$1 "*)
      v="${_annot_opts#*@annotations-"$1" }"
      v="${v%%$'\n'*}"
      case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; esac
      printf '%s' "$v"
      ;;
    *) printf '%s' "$2" ;;
  esac
}

# Back-compat shim: callers pass the full option name.
opt_key() {
  annot_opt "${1#@annotations-}" "$2"
}

_opt_dir="$(annot_opt dir '')"
DATA_DIR="${_opt_dir:-$HOME/.local/share/tmux-annotations}"
NOTES_DIR="$DATA_DIR/notes"
# shellcheck disable=SC2034  # used by the sourcing scripts
STAGE="$DATA_DIR/.stage"
mkdir -p "$NOTES_DIR"

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

# Open a styled popup, degrading gracefully: border/style/title/-e flags
# need tmux >= 3.3 (capability cached in @annotations-caps at load time);
# size is clamped to the client so small terminals don't reject it.
# $1 w, $2 h, $3 title, $4 command, $5/$6 client w/h if already known
open_popup() {
  local w=$1 h=$2 cw="${5:-}" ch="${6:-}" caps wh
  if [ -z "$cw" ] || [ -z "$ch" ]; then
    wh="$(tmux display-message -p '#{client_width} #{client_height}' 2>/dev/null || true)"
    cw="${wh%% *}"
    ch="${wh##* }"
  fi
  case "$cw" in '' | *[!0-9]*) cw=0 ;; esac
  case "$ch" in '' | *[!0-9]*) ch=0 ;; esac
  [ "$cw" -gt 8 ] && [ "$w" -gt $((cw - 2)) ] && w=$((cw - 2))
  [ "$ch" -gt 8 ] && [ "$h" -gt $((ch - 2)) ] && h=$((ch - 2))
  caps="$(annot_opt caps '')"
  if [ -z "$caps" ]; then
    if tmux_at_least 3 3; then caps=33; else caps=32; fi
  fi
  if [ "$caps" -ge 33 ]; then
    # -e hands the popup its interior size so the app can skip tput
    tmux display-popup -w "$w" -h "$h" \
      -e "ANNOT_COLS=$((w - 2))" -e "ANNOT_ROWS=$((h - 2))" \
      -b rounded -S 'fg=colour221' -T "$3" -E "$4"
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

# Render all notes as markdown: quoted selection first, then the note,
# entries separated by a horizontal rule.
notes_as_markdown() {
  local f note first=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    note="$(unesc_note "$(head -n 1 "$f")")"
    [ "$first" = 1 ] || printf '\n---\n\n'
    first=0
    tail -n +2 "$f" | sed 's/^/> /'
    printf '\n%s\n' "$note"
  done < <(list_notes)
}

# Nudge the status line so the annotations indicator updates immediately.
status_refresh() {
  tmux refresh-client -S 2>/dev/null || true
}
