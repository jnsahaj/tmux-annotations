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
#   Enter / Cmd+Enter submit · Shift+Enter / Alt+Enter newline · Esc cancel
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
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

# The copy-pipe that stages the selection runs in parallel with the
# popup opening — wait briefly for it (almost always already there).
tries=0
while ! [ -s "$STAGE" ] && [ "$tries" -lt 30 ]; do
  sleep 0.02
  tries=$((tries + 1))
done
[ -s "$STAGE" ] || exit 0
sel="$(cat "$STAGE")"

# Interior size arrives via -e from open_popup (tmux 3.3+); tput is the
# fallback — two subprocess spawns we skip on the common path.
ROWS="${ANNOT_ROWS:-}"
COLS="${ANNOT_COLS:-}"
case "$ROWS" in '' | *[!0-9]*) ROWS="$(tput lines 2>/dev/null || echo 10)" ;; esac
case "$COLS" in '' | *[!0-9]*) COLS="$(tput cols 2>/dev/null || echo 64)" ;; esac
case "$ROWS" in '' | *[!0-9]*) ROWS=10 ;; esac
case "$COLS" in '' | *[!0-9]*) COLS=64 ;; esac

if has_utf8; then BAR='│' ELL='…' SEP='·'; else BAR='|' ELL='...' SEP='-'; fi

# ── one-line selection preview, truncated with an ellipsis ────────────────
# Pure bash (no tr|sed forks); before LC_ALL=C so truncation counts
# characters, not bytes. Only the head of the selection matters.
preview="${sel:0:400}"
preview="${preview//$'\n'/ }"
preview="${preview//$'\t'/ }"
while [ "${preview#*  }" != "$preview" ]; do preview="${preview//  / }"; done
preview="${preview# }"
preview="${preview% }"
maxw=56
[ "${#preview}" -gt "$maxw" ] && preview="${preview:0:$maxw}$ELL"
printf '\n   \033[2m%s %s\033[0m\n' "$BAR" "$preview"
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

HINT="enter save $SEP shift+enter newline $SEP esc cancel"

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

# ── extended-key parsing ──────────────────────────────────────────────────
# Terminals in kitty CSI-u or modifyOtherKeys mode may CSI-encode ANY key,
# including unmodified ones, and kitty adds :subparams (alternate keys,
# event types). Exact string matches are hopeless — extract keycode and
# modifier numerically and dispatch on those. Modifier = 1 + bitmask
# (shift 1, alt 2, ctrl 4, super/cmd 8).

num() { case "${1:-}" in '' | *[!0-9]*) echo 1 ;; *) echo "$1" ;; esac }

key_u() { # keycode $1, modifier $2 (CSI-u and modifyOtherKeys funnel here)
  local code mod ctrl alt super c
  code="$(num "$1")"
  mod="$(num "$2")"
  ctrl=$(((mod - 1) & 4)); alt=$(((mod - 1) & 2)); super=$(((mod - 1) & 8))
  case "$code" in
    13)
      if [ "$mod" -le 1 ] || [ "$super" -ne 0 ]; then
        SUBMIT=1                                      # Enter / Cmd+Enter
      else
        insert $'\n'                                  # Shift/Alt/Ctrl+Enter
      fi
      ;;
    27) exit 0 ;;                                     # Esc
    127)
      if [ "$super" -ne 0 ]; then
        delete_range "$(line_start "$cur")" "$cur"    # Cmd+Backspace
      elif [ "$ctrl" -ne 0 ] || [ "$alt" -ne 0 ]; then
        delete_range "$(word_left "$cur")" "$cur"     # Opt/Ctrl+Backspace
      else
        delete_range "$(char_left "$cur")" "$cur"
      fi
      ;;
    9) : ;;                                           # Tab — ignore
    *)
      if [ "$ctrl" -ne 0 ]; then
        case "$code" in
          97) cur="$(line_start "$cur")" ;;                    # ^A
          98) cur="$(char_left "$cur")" ;;                     # ^B
          99) exit 0 ;;                                        # ^C
          100) delete_range "$cur" "$(char_right "$cur")" ;;   # ^D
          101) cur="$(line_end "$cur")" ;;                     # ^E
          102) cur="$(char_right "$cur")" ;;                   # ^F
          106) insert $'\n' ;;                                 # ^J
          107) delete_range "$cur" "$(line_end "$cur")" ;;     # ^K
          117) delete_range "$(line_start "$cur")" "$cur" ;;   # ^U
          119) delete_range "$(word_left "$cur")" "$cur" ;;    # ^W
        esac
      elif [ "$alt" -ne 0 ]; then
        case "$code" in
          98) cur="$(word_left "$cur")" ;;                     # Alt+B
          100) delete_range "$cur" "$(word_right "$cur")" ;;   # Alt+D
          102) cur="$(word_right "$cur")" ;;                   # Alt+F
        esac
      elif [ "$code" -ge 32 ] && [ "$code" -le 126 ]; then
        # shellcheck disable=SC2059  # building an octal escape on purpose
        c="$(printf "\\$(printf '%03o' "$code")")"             # encoded printable
        [ "$mod" -eq 2 ] && c="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"
        insert "$c"
      fi
      ;;
  esac
}

key_tilde() { # special key $1 (CSI ~ form), modifier $2
  local code mod
  code="$(num "$1")"
  mod="$(num "$2")"
  case "$code" in
    3)
      if [ "$mod" -ge 3 ]; then
        delete_range "$cur" "$(word_right "$cur")"    # Opt/Ctrl+Del
      else
        delete_range "$cur" "$(char_right "$cur")"    # Del (forward)
      fi
      ;;
    1 | 7) cur="$(line_start "$cur")" ;;              # Home
    4 | 8) cur="$(line_end "$cur")" ;;                # End
  esac
}

key_arrow() { # letter $1, modifier $2
  local k="$1" mod ctrl alt super
  mod="$(num "$2")"
  ctrl=$(((mod - 1) & 4)); alt=$(((mod - 1) & 2)); super=$(((mod - 1) & 8))
  case "$k" in
    D)
      if [ "$super" -ne 0 ]; then cur="$(line_start "$cur")"
      elif [ "$ctrl" -ne 0 ] || [ "$alt" -ne 0 ]; then cur="$(word_left "$cur")"
      else cur="$(char_left "$cur")"; fi
      ;;
    C)
      if [ "$super" -ne 0 ]; then cur="$(line_end "$cur")"
      elif [ "$ctrl" -ne 0 ] || [ "$alt" -ne 0 ]; then cur="$(word_right "$cur")"
      else cur="$(char_right "$cur")"; fi
      ;;
    A) if [ "$super" -ne 0 ]; then cur=0; else cursor_up; fi ;;
    B) if [ "$super" -ne 0 ]; then cur=${#buf}; else cursor_down; fi ;;
    H) cur="$(line_start "$cur")" ;;
    F) cur="$(line_end "$cur")" ;;
  esac
}

handle_csi() {
  local seq="$1" final body f1 f2 f3 rest
  [ -n "$seq" ] || return 0
  final="${seq:$((${#seq} - 1)):1}"
  body="${seq%?}"
  case "$final" in
    u)
      f1="${body%%;*}"
      f2=''
      case "$body" in *\;*) f2="${body#*;}"; f2="${f2%%;*}" ;; esac
      key_u "${f1%%:*}" "${f2%%:*}"
      ;;
    '~')
      f1="${body%%;*}"
      rest=''
      case "$body" in *\;*) rest="${body#*;}" ;; esac
      f2="${rest%%;*}"
      f3=''
      case "$rest" in *\;*) f3="${rest#*;}"; f3="${f3%%;*}" ;; esac
      if [ "${f1%%:*}" = 27 ] && [ -n "$f3" ]; then
        key_u "${f3%%:*}" "${f2%%:*}"                 # xterm 27;mod;code~ form
      else
        key_tilde "${f1%%:*}" "${f2%%:*}"
      fi
      ;;
    A | B | C | D | H | F)
      f2=''
      case "$body" in *\;*) f2="${body#*;}"; f2="${f2%%[:;]*}" ;; esac
      key_arrow "$final" "$f2"
      ;;
  esac
}

SUBMIT=0
draw
while IFS= read -rsn1 key; do
  [ -e /tmp/annot-keylog-on ] && printf '%q\n' "$key" >> /tmp/annot-keylog
  case "$key" in
    $'\r') break ;;                                   # Enter → submit
    # \n also submits: some tty layers deliver Enter as \n (icrnl), and a
    # note editor must never leave Enter meaning "newline" with no way to
    # save. Costs Ctrl+J-as-newline — Shift/Alt+Enter cover that.
    '') break ;;
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
    $'\x04') delete_range "$cur" "$(char_right "$cur")" ;;     # Ctrl+D
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
