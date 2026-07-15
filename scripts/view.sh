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
  BAR='│' ELL='…' SEP='·' RULE='─'
else
  BAR='|' ELL='...' SEP='-' RULE='-'
fi

if [ "${1:-}" != "--inside" ]; then
  count="$(note_count)"
  if [ "$count" -eq 0 ]; then
    tmux display-message "annotations: none yet — select text in copy mode and press $ANNOTATE_KEY"
    exit 0
  fi
  open_popup 72 24 ' Annotations ' "'$0' --inside"
  exit 0
fi

# ── styles ────────────────────────────────────────────────────────────────
RESET=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'

COLS="${ANNOT_COLS:-}"
ROWS="${ANNOT_ROWS:-}"
case "$COLS" in '' | *[!0-9]*) COLS="$(tput cols 2>/dev/null || echo 70)" ;; esac
case "$ROWS" in '' | *[!0-9]*) ROWS="$(tput lines 2>/dev/null || echo 22)" ;; esac
case "$COLS" in '' | *[!0-9]*) COLS=70 ;; esac
case "$ROWS" in '' | *[!0-9]*) ROWS=22 ;; esac
W=$((COLS - 4))
[ "$W" -gt 64 ] && W=64
MAX_SEL_LINES=6

# ── build the full frame into BUF (one entry per screen row) ─────────────
BUF=()

trunc() { # truncate $1 to $2 chars, appending an ellipsis when cut
  local t="${1//$'\t'/  }"   # tabs render 8 wide and wreck alignment
  if [ "${#t}" -gt "$2" ]; then
    printf '%s%s' "${t:0:$(($2 - 1))}" "$ELL"
  else
    printf '%s' "$t"
  fi
}

rule() { # dim separator between annotations
  local out=''
  while [ "${#out}" -lt "$W" ]; do out="$out$RULE"; done
  BUF+=("  ${DIM}${out}${RESET}")
}

build() {
  BUF=()
  local f note line n shown first=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    note="$(unesc_note "$(head -n 1 "$f")")"

    if [ "$first" = 1 ]; then
      first=0
      BUF+=("")
    else
      BUF+=("")
      rule
      BUF+=("")
    fi
    # quoted selection first: one row per line, char-truncated w/ ellipsis
    n="$(tail -n +2 "$f" | wc -l | tr -d ' ')"
    shown=0
    while IFS= read -r line && [ "$shown" -lt "$MAX_SEL_LINES" ]; do
      BUF+=("   ${DIM}${BAR} $(trunc "$line" $((W - 4)))${RESET}")
      shown=$((shown + 1))
    done < <(tail -n +2 "$f")
    [ "$n" -gt "$MAX_SEL_LINES" ] && BUF+=("   ${DIM}${BAR} $ELL $((n - MAX_SEL_LINES)) more lines${RESET}")
    # then the note, wrapped, bold
    while IFS= read -r line; do
      BUF+=("  ${BOLD}${line}${RESET}")
    done < <(printf '%s\n' "$note" | fold -s -w "$W")
  done < <(list_notes)
}

# ── draw loop ─────────────────────────────────────────────────────────────
offset=0
while true; do
  build
  total=${#BUF[@]}
  count="$(note_count)"

  if [ "$count" -eq 0 ]; then
    printf '\e[2J\e[H\n   %sall annotations copied & cleared%s\n\n   press any key to close' "$DIM" "$RESET"
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
        status_refresh
        tmux display-message "annotations: $count deleted"
        exit 0
      fi
      ;;
    "$VIEW_KEY" | q) exit 0 ;;
    j) offset=$((offset + 2)) ;;
    k) offset=$((offset - 2)) ;;
  esac
done
