#!/usr/bin/env bash
# Runs inside the input popup: shows a preview of the staged selection,
# reads the note, saves both as a note file.
#
# The note input is a small textarea implemented as a raw key loop —
# bash `read -e` can't do multiline or distinguish Shift+Enter. It keeps
# a byte cursor into the buffer (LC_ALL=C, with UTF-8-aware motion so
# multibyte characters move/delete as one unit).
#
# Keys:
#   Enter submit · Shift+Enter / Alt+Enter / Ctrl+J newline · Esc cancel
#   arrows / Ctrl+B/F move · Opt+arrows / Alt+B/F word · Cmd+arrows,
#   Home/End, Ctrl+A/E line start/end · Cmd+Up/Down buffer start/end
#   Backspace / Del char · Opt+Backspace, Ctrl+W / Alt+D word back/fwd
#   Cmd+Backspace, Ctrl+U to line start · Ctrl+K to line end
#
# Shift+Enter and the Cmd/Opt combos need an extended-key protocol —
# kitty CSI-u or xterm modifyOtherKeys, both enabled below, both parsed.
# Classic encodings (ESC DEL, ESC b/f, ctrl keys) are handled as
# fallbacks so word ops work on plain terminals too.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/helpers.sh"

[ -s "$STAGE" ] || exit 0
sel="$(cat "$STAGE")"

ROWS="$(tput lines 2>/dev/null || echo 10)"
COLS="$(tput cols 2>/dev/null || echo 64)"

# ── one-line selection preview, truncated with an ellipsis ────────────────
# (before LC_ALL=C so truncation counts characters, not bytes)
preview="$(printf '%s' "$sel" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
maxw=56
[ "${#preview}" -gt "$maxw" ] && preview="${preview:0:$maxw}…"
printf '\n   \033[2m│ %s\033[0m\n' "$preview"
ORIGIN=4

export LC_ALL=C   # byte-indexed buffer; motion helpers handle UTF-8

# ── raw keyboard setup ────────────────────────────────────────────────────
stty -icrnl 2>/dev/null || true          # keep Enter as \r, Ctrl+J as \n
printf '\e[>4;2m\e[>1u'                  # modifyOtherKeys=2 + kitty push
cleanup() {
  printf '\e[<u\e[>4;0m\e[?25h'
  stty icrnl 2>/dev/null || true
}
trap cleanup EXIT

HINT='enter save · shift+enter newline · esc cancel'

buf=''
cur=0

# ── buffer motion (byte cursor, UTF-8 aware) ──────────────────────────────
is_cont() { # is $1 a UTF-8 continuation byte?
  local b
  b="$(printf '%d' "'${1:-}" 2>/dev/null || echo 0)"
  b=$((b & 255))   # bash 3.2 reports high bytes as signed chars
  [ "$b" -ge 128 ] && [ "$b" -lt 192 ]
}

is_space() {
  case "${1:-}" in ' ' | $'\t' | $'\n') return 0 ;; *) return 1 ;; esac
}

char_left() {
  local p=$1
  [ "$p" -le 0 ] && { echo 0; return; }
  p=$((p - 1))
  while [ "$p" -gt 0 ] && is_cont "${buf:$p:1}"; do p=$((p - 1)); done
  echo "$p"
}

char_right() {
  local p=$1 len=${#buf}
  [ "$p" -ge "$len" ] && { echo "$len"; return; }
  p=$((p + 1))
  while [ "$p" -lt "$len" ] && is_cont "${buf:$p:1}"; do p=$((p + 1)); done
  echo "$p"
}

word_left() {
  local p=$1
  while [ "$p" -gt 0 ] && is_space "${buf:$((p - 1)):1}"; do p=$((p - 1)); done
  while [ "$p" -gt 0 ] && ! is_space "${buf:$((p - 1)):1}"; do p=$((p - 1)); done
  echo "$p"
}

word_right() {
  local p=$1 len=${#buf}
  while [ "$p" -lt "$len" ] && is_space "${buf:$p:1}"; do p=$((p + 1)); done
  while [ "$p" -lt "$len" ] && ! is_space "${buf:$p:1}"; do p=$((p + 1)); done
  echo "$p"
}

line_start() {
  local p=$1
  while [ "$p" -gt 0 ] && [ "${buf:$((p - 1)):1}" != $'\n' ]; do p=$((p - 1)); done
  echo "$p"
}

line_end() {
  local p=$1 len=${#buf}
  while [ "$p" -lt "$len" ] && [ "${buf:$p:1}" != $'\n' ]; do p=$((p + 1)); done
  echo "$p"
}

delete_range() { # delete [$1, $2), cursor lands at $1
  [ "$1" -ge "$2" ] && return
  buf="${buf:0:$1}${buf:$2}"
  cur=$1
}

insert() {
  buf="${buf:0:$cur}$1${buf:$cur}"
  cur=$((cur + ${#1}))
}

cursor_up() {
  local ls col pls
  ls="$(line_start "$cur")"
  [ "$ls" -eq 0 ] && return
  col=$((cur - ls))
  pls="$(line_start $((ls - 1)))"
  local plen=$((ls - 1 - pls))
  [ "$col" -gt "$plen" ] && col=$plen
  cur=$((pls + col))
}

cursor_down() {
  local ls col le len=${#buf} nls nle nlen
  le="$(line_end "$cur")"
  [ "$le" -ge "$len" ] && return
  ls="$(line_start "$cur")"
  col=$((cur - ls))
  nls=$((le + 1))
  nle="$(line_end "$nls")"
  nlen=$((nle - nls))
  [ "$col" -gt "$nlen" ] && col=$nlen
  cur=$((nls + col))
}

# ── drawing (soft wrap: long logical lines break at WRAP_W, every
# display row keeps the 3-column indent; cursor math mirrors the wrap) ────
WRAP_W=$((COLS - 4))
[ "$WRAP_W" -lt 10 ] && WRAP_W=10

wrap_rows() { # display rows a logical line of length $1 occupies
  if [ "$1" -eq 0 ]; then
    echo 1
  else
    echo $((($1 + WRAP_W - 1) / WRAP_W))
  fi
}

draw() {
  local line pre crow ccol nrows=0
  printf '\e[?25l\e[?7l\e[%d;1H\e[J' "$ORIGIN"
  while IFS= read -r line; do
    while [ "${#line}" -gt "$WRAP_W" ]; do
      printf '   %s\n' "${line:0:$WRAP_W}"
      line="${line:$WRAP_W}"
    done
    printf '   %s\n' "$line"
  done <<< "$buf"
  printf '\e[%d;1H  \e[2m%s\e[0m' "$ROWS" "$HINT"
  # cursor: full logical lines before it, then wrap position in its line
  pre="${buf:0:$cur}"
  while [ "$pre" != "${pre#*$'\n'}" ]; do
    line="${pre%%$'\n'*}"
    nrows=$((nrows + $(wrap_rows "${#line}")))
    pre="${pre#*$'\n'}"
  done
  crow=$((ORIGIN + nrows + ${#pre} / WRAP_W))
  ccol=$((4 + ${#pre} % WRAP_W))
  printf '\e[?7h\e[%d;%dH\e[?25h' "$crow" "$ccol"
}

# NOTE: read -t must be an integer — /bin/bash 3.2 rejects fractional
# timeouts (read fails instantly, indistinguishable from a timeout).
read_csi() { # after ESC [ — collect until a final byte, echo the sequence
  local seq='' ch
  while IFS= read -rsn1 -t 1 ch; do
    seq+="$ch"
    case "$ch" in [@A-Za-z~]) break ;; esac
  done
  printf '%s' "$seq"
}

# Extended-key protocols encode UNMODIFIED keys too (modifier field "1"
# or absent) — those must map back to their legacy meaning, and before
# the modifier wildcards below or plain Enter becomes a newline.
handle_csi() {
  case "$1" in
    13u | 13\;1u | 27\;1\;13~) SUBMIT=1 ;;            # plain Enter
    13\;*u | 27\;*\;13~) insert $'\n' ;;              # Shift/mod+Enter
    27u | 27\;1u | 27\;1\;27~) exit 0 ;;              # Esc
    3~) delete_range "$cur" "$(char_right "$cur")" ;; # Del (forward)
    3\;3~ | 3\;5~) delete_range "$cur" "$(word_right "$cur")" ;;
    127\;3u | 127\;4u | 27\;[34]\;127~) delete_range "$(word_left "$cur")" "$cur" ;;    # Opt+BS
    127\;9u | 127\;10u | 127\;13u | 27\;9\;127~ | 27\;13\;127~) delete_range "$(line_start "$cur")" "$cur" ;; # Cmd+BS
    127u | 127\;*u | 27\;*\;127~) delete_range "$(char_left "$cur")" "$cur" ;; # Backspace
    D) cur="$(char_left "$cur")" ;;
    C) cur="$(char_right "$cur")" ;;
    A) cursor_up ;;
    B) cursor_down ;;
    1\;3D | 1\;5D) cur="$(word_left "$cur")" ;;       # Opt/Ctrl+Left
    1\;3C | 1\;5C) cur="$(word_right "$cur")" ;;
    1\;9D | 1\;13D) cur="$(line_start "$cur")" ;;     # Cmd+Left
    1\;9C | 1\;13C) cur="$(line_end "$cur")" ;;
    1\;9A) cur=0 ;;                                   # Cmd+Up
    1\;9B) cur=${#buf} ;;                             # Cmd+Down
    1\;*D) cur="$(char_left "$cur")" ;;
    1\;*C) cur="$(char_right "$cur")" ;;
    1\;*A) cursor_up ;;
    1\;*B) cursor_down ;;
    H | 1~ | 7~) cur="$(line_start "$cur")" ;;        # Home
    F | 4~ | 8~) cur="$(line_end "$cur")" ;;          # End
  esac
}

SUBMIT=0
draw
while IFS= read -rsn1 key; do
  case "$key" in
    $'\r') break ;;                                   # Enter → submit
    '') insert $'\n' ;;                               # Ctrl+J
    $'\e')
      if ! IFS= read -rsn1 -t 1 k2; then
        exit 0                                        # bare Esc → cancel
      fi
      case "$k2" in
        $'\r') insert $'\n' ;;                        # Alt+Enter
        $'\x7f') delete_range "$(word_left "$cur")" "$cur" ;; # Opt+BS classic
        b) cur="$(word_left "$cur")" ;;               # Alt+B
        f) cur="$(word_right "$cur")" ;;              # Alt+F
        d) delete_range "$cur" "$(word_right "$cur")" ;; # Alt+D
        '[') handle_csi "$(read_csi)" ;;
      esac
      ;;
    $'\x7f' | $'\b') delete_range "$(char_left "$cur")" "$cur" ;;
    $'\x17') delete_range "$(word_left "$cur")" "$cur" ;;      # Ctrl+W
    $'\x15') delete_range "$(line_start "$cur")" "$cur" ;;     # Ctrl+U
    $'\x0b') delete_range "$cur" "$(line_end "$cur")" ;;       # Ctrl+K
    $'\x01') cur="$(line_start "$cur")" ;;                     # Ctrl+A
    $'\x05') cur="$(line_end "$cur")" ;;                       # Ctrl+E
    $'\x02') cur="$(char_left "$cur")" ;;                      # Ctrl+B
    $'\x06') cur="$(char_right "$cur")" ;;                     # Ctrl+F
    $'\x03') exit 0 ;;                                         # Ctrl+C
    *)
      # insert printables (incl. multibyte bytes), ignore stray control bytes
      if ! [[ "$key" < ' ' ]]; then insert "$key"; fi
      ;;
  esac
  [ "$SUBMIT" = 1 ] && break
  draw
done

# trim trailing newlines; require something left
while [ "${buf%$'\n'}" != "$buf" ]; do buf="${buf%$'\n'}"; done
[ -n "$buf" ] || exit 0

file="$NOTES_DIR/$(date +%s)-$RANDOM.note"
{
  printf '%s\n' "$(esc_note "$buf")"
  printf '%s\n' "$sel"
} > "$file"
rm -f "$STAGE"

tmux display-message "annotations: saved — $(note_count) total. prefix+$(opt_key @annotations-view-key a) to view"
