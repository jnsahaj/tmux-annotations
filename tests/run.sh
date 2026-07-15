#!/usr/bin/env bash
# Test suite: drives the note editor with raw byte sequences over a pipe
# (pipes deliver bytes verbatim — no pty cooking) and checks what gets
# saved. Also unit-tests the tmux version parser. Needs tmux + bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$HOME/.local/share/tmux-annotations"
mkdir -p "$D/notes"   # fresh machines: the stage write below needs it
SOCK="annotest-$$"

tmux -L "$SOCK" -f /dev/null new-session -d -x 80 -y 24
TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),0,0"
export TMUX
trap 'tmux -L "$SOCK" kill-server 2>/dev/null' EXIT

pass=0
fail=0

t() { # $1=name  $2=raw input bytes  $3=expected line1 of note ("NONE" = no save)
  printf 'selected text line\n' > "$D/.stage"
  rm -f "$D"/notes/*.note
  # shellcheck disable=SC2059  # test inputs are printf escape strings
  printf "$2" | bash "$ROOT/scripts/add.sh" >/dev/null 2>&1
  local f got
  # shellcheck disable=SC2012  # filenames are ours: epoch-rand.note
  f="$(ls "$D"/notes/*.note 2>/dev/null | head -1)"
  if [ -n "$f" ]; then got="$(head -1 "$f")"; else got="NONE"; fi
  if [ "$got" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   %-30s [%s]\n' "$1" "$got"
  else
    fail=$((fail + 1)); printf 'FAIL %-30s got [%s] want [%s]\n' "$1" "$got" "$3"
  fi
}

echo "== editor: basics =="
t "plain enter"              'hello\r'                              'hello'
t "esc cancels"              'x\x1b'                                'NONE'
t "ctrl+c cancels"           'x\x03'                                'NONE'
t "empty note not saved"     '\r'                                   'NONE'
t "backspace"                'abcd\x7f\x7fZ\r'                      'abZ'
t "control bytes ignored"    'a\x04\x06b\r'                         'ab'

echo "== editor: newlines =="
t "shift+enter (kitty)"      'a\x1b[13;2ub\r'                       'a\nb'
t "shift+enter (mok)"        'a\x1b[27;2;13~b\r'                    'a\nb'
t "alt+enter + ctrl+j"       'x\x1b\ry\x0az\r'                      'x\ny\nz'

echo "== editor: cursor movement =="
t "left arrow + insert"      'ab\x1b[Dc\r'                          'acb'
t "ctrl+a home"              'bc\x01a\r'                            'abc'
t "home key (CSI H)"         'bc\x1b[Ha\r'                          'abc'
t "end after home"           'bc\x1b[H\x1b[Fd\r'                    'bcd'
t "cmd+left (1;9D)"          'bc\x1b[1;9Da\r'                       'abc'
t "opt+left word (1;3D)"     'hello world\x1b[1;3DX\r'              'hello Xworld'
t "alt+b classic"            'hi yo\x1bbX\r'                        'hi Xyo'
t "cmd+up then insert"       'bc\x1b[1;9Aa\r'                       'abc'
t "up/down across lines"     'abc\x0adef\x1b[A\x1b[3~\r'            'abcdef'

echo "== editor: deletion =="
t "opt+bs (classic ESC-DEL)" 'hello world\x1b\x7f\r'                'hello '
t "opt+bs (CSI 127;3u)"      'hello world\x1b[127;3u\r'             'hello '
t "ctrl+w word back"         'hello world\x17\r'                    'hello '
t "cmd+bs (CSI 127;9u)"      'line1\x1b[13;2uab cd\x1b[127;9uZ\r'   'line1\nZ'
t "ctrl+u to line start"     'ab cd\x15Z\r'                         'Z'
t "del forward (CSI 3~)"     'abc\x1b[D\x1b[D\x1b[3~\r'             'ac'
t "ctrl+d raw"               'ab\x01\x04\r'                         'b'
t "alt+d del word fwd"       'hi yo\x01\x1bd\r'                     ' yo'
t "ctrl+k kill to eol"       'abcd\x01\x0bZ\r'                      'Z'
t "multibyte em-dash bs"     'a\xe2\x80\x94b\x7f\x7f\r'             'a'

echo "== editor: CSI-encoded plain keys (encode-all modes) =="
t "enter as 13u"             'hi\x1b[13u'                           'hi'
t "enter as 13;1u"           'hi\x1b[13;1u'                         'hi'
t "enter as 27;1;13~"        'hi\x1b[27;1;13~'                      'hi'
t "enter as 13;1:1u"         'hi\x1b[13;1:1u'                       'hi'
t "esc as 27;1:1u"           'hi\x1b[27;1:1u'                       'NONE'
t "esc as 27;1;27~"          'hi\x1b[27;1;27~'                      'NONE'
t "ctrl+c as 99;5u"          'hi\x1b[99;5u'                         'NONE'
t "bs as 127;1:1u"           'abc\x1b[127;1:1u\r'                   'ab'
t "bs as 27;1;127~"          'abc\x1b[27;1;127~\r'                  'ab'
t "opt+bs as 127;3:1u"       'hello world\x1b[127;3:1u\r'           'hello '
t "opt+bs as 27;3;127~"      'hello world\x1b[27;3;127~\r'          'hello '
t "cmd+bs as 127;9:1u"       'ab cd\x1b[127;9:1uZ\r'                'Z'
t "encoded letter 104;1u"    '\x1b[104;1ui\r'                       'hi'
t "encoded shift letter"     '\x1b[104;2u\r'                        'H'
t "ctrl+a as 97;5u"          'bc\x1b[97;5ua\r'                      'abc'
t "ctrl+d as 100;5u"         'ab\x1b[1;9D\x1b[100;5u\r'             'b'
t "alt+b as 98;3u"           'hi yo\x1b[98;3uX\r'                   'hi Xyo'
t "del as 3;1:1~"            'abc\x1b[D\x1b[D\x1b[3;1:1~\r'         'ac'
t "arrow as 1;1:1D"          'ab\x1b[1;1:1Dc\r'                     'acb'
t "shift+enter as 13;2:1u"   'a\x1b[13;2:1ub\r'                     'a\nb'

echo "== editor: long input =="
t "long line survives"       'this is a fairly long single line that must wrap around the popup width just fine\r' 'this is a fairly long single line that must wrap around the popup width just fine'

echo "== markdown rendering =="
printf 'selected text line\n' > "$D/.stage"
rm -f "$D"/notes/*.note
printf 'first line\x1b[13;2usecond line\r' | bash "$ROOT/scripts/add.sh" >/dev/null 2>&1
md="$(cd "$ROOT" && bash -c '. scripts/helpers.sh && notes_as_markdown')"
case "$md" in
  '## first line'*'second line'*'> selected text line'*)
    pass=$((pass + 1)); echo "ok   multiline markdown render" ;;
  *)
    fail=$((fail + 1)); echo "FAIL multiline markdown render:"; printf '%s\n' "$md" ;;
esac
rm -f "$D"/notes/*.note

echo "== tmux_at_least parsing =="
v() { # $1 fake version string, $2 maj, $3 min, $4 expected yes/no
  local got
  got="$(
    # shellcheck disable=SC2329  # shadows tmux for the sourced helpers
    tmux() { if [ "${1:-}" = "-V" ]; then echo "$FAKE"; else command tmux "$@"; fi; }
    FAKE="$1"
    # shellcheck source=scripts/helpers.sh disable=SC1091
    . "$ROOT/scripts/helpers.sh"
    if tmux_at_least "$2" "$3"; then echo yes; else echo no; fi
  )"
  if [ "$got" = "$4" ]; then
    pass=$((pass + 1)); echo "ok   [$1] >= $2.$3 -> $got"
  else
    fail=$((fail + 1)); echo "FAIL [$1] >= $2.$3 -> $got (want $4)"
  fi
}
v "tmux 3.1c" 3 2 no
v "tmux 3.2a" 3 2 yes
v "tmux 3.2a" 3 3 no
v "tmux 3.3a" 3 3 yes
v "tmux next-3.6" 3 2 yes
v "tmux openbsd-7.4" 3 2 yes
v "tmux master" 3 2 yes
v "tmux 2.9" 3 2 no

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
