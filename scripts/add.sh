#!/usr/bin/env bash
# Runs inside the input popup: shows a preview of the staged selection,
# reads the note, saves both as a note file.
#
# The note input is a raw key loop rather than `read` so that
# Shift+Enter / Alt+Enter / Ctrl+J insert a newline while plain Enter
# submits. Shift+Enter needs the terminal to speak an extended-key
# protocol (kitty CSI-u or xterm modifyOtherKeys) — both are enabled
# below and both encodings are parsed; Alt+Enter works everywhere.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/helpers.sh"

[ -s "$STAGE" ] || exit 0
sel="$(cat "$STAGE")"

ROWS="$(tput lines 2>/dev/null || echo 10)"

# ── one-line selection preview, truncated with an ellipsis ────────────────
preview="$(printf '%s' "$sel" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
maxw=56
[ "${#preview}" -gt "$maxw" ] && preview="${preview:0:$maxw}…"
printf '\n   \033[2m│ %s\033[0m\n' "$preview"
ORIGIN=4

# ── raw keyboard setup ────────────────────────────────────────────────────
stty -icrnl 2>/dev/null || true          # keep Enter as \r, Ctrl+J as \n
printf '\e[>4;2m\e[>1u'                  # modifyOtherKeys=2 + kitty push
cleanup() {
  printf '\e[<u\e[>4;0m'
  stty icrnl 2>/dev/null || true
}
trap cleanup EXIT

HINT='enter save · shift+enter newline · esc cancel'

buf=''
draw() {
  printf '\e[%d;1H\e[J' "$ORIGIN"
  printf '   %s' "${buf//$'\n'/$'\n'   }"
  printf '\e7\e[%d;1H  \e[2m%s\e[0m\e8' "$ROWS" "$HINT"
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

draw
while IFS= read -rsn1 key; do
  case "$key" in
    $'\r') break ;;                       # Enter → submit
    '') buf+=$'\n' ;;                     # Ctrl+J → newline
    $'\e')
      if ! IFS= read -rsn1 -t 1 k2; then
        exit 0                            # bare Esc → cancel
      fi
      case "$k2" in
        $'\r') buf+=$'\n' ;;              # Alt+Enter → newline
        '[')
          seq="$(read_csi)"
          case "$seq" in
            13\;*u | 27\;*\;13~) buf+=$'\n' ;;  # Shift/mod+Enter
            27u) exit 0 ;;                       # Esc (kitty encoding)
          esac
          ;;
      esac
      ;;
    $'\x7f' | $'\b') buf="${buf%?}" ;;    # backspace
    $'\x15') buf='' ;;                    # Ctrl+U → clear
    $'\x03') exit 0 ;;                    # Ctrl+C → cancel
    *)
      # append printables (incl. multibyte bytes), ignore stray control bytes
      if ! [[ "$key" < ' ' ]]; then buf+="$key"; fi
      ;;
  esac
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
