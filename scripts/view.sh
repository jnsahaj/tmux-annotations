#!/usr/bin/env bash
# Toggle the floating annotations overlay.
# Outer call opens a popup running this same script with --inside;
# --inside renders sticky-note blocks and handles keys:
#   j/k or arrows scroll · Y copy all & clear · d delete all (confirmed)
#   q / Esc / <view-key> close
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh disable=SC1091
. "$DIR/helpers.sh"

VIEW_KEY="$(opt_key @annotations-view-key a)"
ANNOTATE_KEY="$(opt_key @annotations-key i)"
COPY_KEY="$(opt_key @annotations-copy-key Y)"
DELETE_KEY="$(opt_key @annotations-delete-key d)"

if has_utf8; then
  PEN='✎' CURL='◣' BAR='▏' ELL='…' SEP='·'
else
  PEN='*' CURL=' ' BAR='|' ELL='...' SEP='-'
fi

if [ "${1:-}" != "--inside" ]; then
  count="$(note_count)"
  if [ "$count" -eq 0 ]; then
    tmux display-message "annotations: none yet — select text in copy mode and press $ANNOTATE_KEY"
    exit 0
  fi
  open_popup 72 24 " $PEN annotations " "'$0' --inside"
  exit 0
fi

# ── styles ────────────────────────────────────────────────────────────────
PAPER=$'\e[48;5;229m'   # sticky-note yellow
INK=$'\e[38;5;236m'     # near-black ink
FAINT=$'\e[38;5;101m'   # olive-grey for quoted selection
EDGE=$'\e[38;5;223m'    # curled-corner shadow
RESET=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'

COLS="$(tput cols 2>/dev/null || echo 70)"
ROWS="$(tput lines 2>/dev/null || echo 22)"
case "$COLS" in '' | *[!0-9]*) COLS=70 ;; esac
case "$ROWS" in '' | *[!0-9]*) ROWS=22 ;; esac
NOTE_W=$((COLS - 6))
[ "$NOTE_W" -gt 60 ] && NOTE_W=60
INNER=$((NOTE_W - 2))
MAX_SEL_LINES=6

# ── build the full frame into BUF (one entry per screen row) ─────────────
BUF=()

pad() { # pad/truncate $1 to INNER chars (${#} is char-aware, unlike printf %-*s)
  local t="$1" n
  if [ "${#t}" -gt "$INNER" ]; then
    printf '%s' "${t:0:$INNER}"
    return
  fi
  n=$((INNER - ${#t}))
  printf '%s%*s' "$t" "$n" ''
}

paper_line() { # $1 = styled prefix, $2 = raw text
  BUF+=("  ${PAPER}${INK} ${1}$(pad "$2")${RESET}")
}

build() {
  BUF=()
  local f base epoch note when line n shown
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    epoch="${base%%-*}"
    when="$(fmt_time "$epoch")"
    note="$(unesc_note "$(head -n 1 "$f")")"

    BUF+=("")
    # top edge with a "curl" on the right corner
    BUF+=("  ${PAPER}${EDGE} $(printf '%*s' "$INNER" '')${RESET}${EDGE}${CURL}${RESET}")
    paper_line "${DIM}" "$PEN $when"
    # wrapped note text (possibly multiline), bold
    while IFS= read -r line; do
      paper_line "${BOLD}" "$line"
    done < <(printf '%s\n' "$note" | fold -s -w "$INNER")
    paper_line "" ""
    # quoted selection, capped
    n="$(tail -n +2 "$f" | wc -l | tr -d ' ')"
    shown=0
    while IFS= read -r line && [ "$shown" -lt "$MAX_SEL_LINES" ]; do
      paper_line "${FAINT}" "$BAR ${line}"
      shown=$((shown + 1))
    done < <(tail -n +2 "$f" | cut -c1-"$((INNER - 2))")
    [ "$n" -gt "$MAX_SEL_LINES" ] && paper_line "${FAINT}" "$BAR $ELL $((n - MAX_SEL_LINES)) more lines"
    BUF+=("  ${PAPER} $(printf '%*s' "$INNER" '') ${RESET}")
  done < <(list_notes)
}

# ── draw loop ─────────────────────────────────────────────────────────────
offset=0
while true; do
  build
  total=${#BUF[@]}
  count="$(note_count)"

  if [ "$count" -eq 0 ]; then
    printf '\e[2J\e[H\n   %sall annotations copied & cleared%s\n\n   press any key to close…' "$DIM" "$RESET"
    IFS= read -rsn1 _
    exit 0
  fi

  body=$((ROWS - 3))
  max_off=$((total - body)); [ "$max_off" -lt 0 ] && max_off=0
  [ "$offset" -gt "$max_off" ] && offset=$max_off
  [ "$offset" -lt 0 ] && offset=0

  printf '\e[2J\e[H'
  printf '  %s%s annotation(s)%s\n' "$DIM" "$count" "$RESET"
  for ((i = offset; i < offset + body && i < total; i++)); do
    printf '%s\n' "${BUF[$i]}"
  done
  # footer pinned to the last row
  printf '\e[%d;1H  %sj/k scroll %s %s copy all & clear %s %s delete all %s q close%s' \
    "$ROWS" "$DIM" "$SEP" "$COPY_KEY" "$SEP" "$DELETE_KEY" "$SEP" "$RESET"

  IFS= read -rsn1 key
  if [ "$key" = $'\e' ]; then
    IFS= read -rsn2 -t 0.02 rest || rest=""
    case "$rest" in
      '[A') key=k ;;
      '[B') key=j ;;
      '') exit 0 ;;   # bare Esc
      *) continue ;;
    esac
  fi
  case "$key" in
    "$COPY_KEY") "$DIR/copy.sh"; exit 0 ;;
    "$DELETE_KEY")
      printf '\e[%d;1H\e[2K  %sdelete all %s annotation(s) without copying? (y/n)%s' \
        "$ROWS" "$BOLD" "$count" "$RESET"
      IFS= read -rsn1 yn
      if [ "$yn" = y ]; then
        rm -f "$NOTES_DIR"/*.note
        tmux display-message "annotations: $count deleted"
        exit 0
      fi
      ;;
    "$VIEW_KEY" | q) exit 0 ;;
    j) offset=$((offset + 2)) ;;
    k) offset=$((offset - 2)) ;;
  esac
done
