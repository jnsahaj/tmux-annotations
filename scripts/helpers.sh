# shellcheck shell=bash
# Shared helpers — sourced by every script.

_opt_dir="$(tmux show-option -gqv @annotations-dir 2>/dev/null || true)"
DATA_DIR="${_opt_dir:-$HOME/.local/share/tmux-annotations}"
NOTES_DIR="$DATA_DIR/notes"
STAGE="$DATA_DIR/.stage"
mkdir -p "$NOTES_DIR"

# Resolve a configured key, for hints in messages.
opt_key() {
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  printf '%s' "${v:-$2}"
}

# List note files oldest-first (filenames start with epoch seconds).
list_notes() {
  ls "$NOTES_DIR"/*.note 2>/dev/null | sort
}

note_count() {
  list_notes | wc -l | tr -d ' '
}

# Epoch → "Jul 15 14:32" (BSD date first, GNU fallback).
fmt_time() {
  date -r "$1" '+%b %d %H:%M' 2>/dev/null || date -d "@$1" '+%b %d %H:%M'
}

# stdin → system clipboard (best available), and always into the tmux buffer.
clip_copy() {
  local tmpf
  tmpf="$(mktemp)"
  cat > "$tmpf"
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy < "$tmpf"
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy < "$tmpf"
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "$tmpf"
  fi
  tmux load-buffer "$tmpf" 2>/dev/null || true
  rm -f "$tmpf"
}

# Render all notes as markdown: "## note (time)" + "> selection" blocks.
notes_as_markdown() {
  local f base epoch first=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    epoch="${base%%-*}"
    [ "$first" = 1 ] || printf '\n'
    first=0
    printf '## %s  (%s)\n\n' "$(head -n 1 "$f")" "$(fmt_time "$epoch")"
    tail -n +2 "$f" | sed 's/^/> /'
  done < <(list_notes)
}
