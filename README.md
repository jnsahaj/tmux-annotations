# tmux-annotations ✎

Leave comments on your terminal scrollback.

Select text in copy mode, attach a note to it, keep working — then dump
all your annotations to the clipboard as tidy markdown, ready to paste
into an issue, PR review, or message.

## Usage

| Where | Key | Action |
|---|---|---|
| copy mode, with a selection | `i` | annotate the selection (floating input box) |
| anywhere | `prefix + a` | toggle the annotations overlay |
| overlay (or `prefix + Y`) | `Y` | copy **all** annotations to clipboard as markdown, then clear them |
| overlay | `j` / `k` / arrows | scroll |
| overlay | `q` / `Esc` / `a` | close |

Annotations are invisible until you toggle the overlay, so they never
cover your content. (tmux's scrollback is read-only and popups are modal,
so persistent in-place margin notes aren't possible — the overlay is the
closest tmux allows.)

What lands on your clipboard:

```markdown
## check this error later  (Jul 15 14:32)

> Error: connect ECONNREFUSED 127.0.0.1:5432
>     at TCPConnectWrap.afterConnect
```

Copied via `pbcopy` / `wl-copy` / `xclip` (whichever exists), and always
into the tmux paste buffer too.

## Install

Requires tmux ≥ 3.2 (popups).

### TPM

```tmux
set -g @plugin 'jnsahaj/tmux-annotations'
```

Then `prefix + I` to install.

### Manual

```sh
git clone https://github.com/jnsahaj/tmux-annotations ~/.tmux/tmux-annotations
```

```tmux
# in tmux.conf
run-shell ~/.tmux/tmux-annotations/annotations.tmux
```

## Configuration

All keybindings and the storage location are options (set them in
`tmux.conf` **before** the plugin loads; defaults shown):

```tmux
set -g @annotations-key 'i'        # annotate key (copy-mode table)
set -g @annotations-view-key 'a'   # toggle overlay (prefix table)
set -g @annotations-copy-key 'Y'   # copy all & clear (prefix table)
set -g @annotations-dir '~/.local/share/tmux-annotations'
```

## Storage

Each annotation is a plain file in `<dir>/notes/<epoch>-<rand>.note`:
first line is your comment, the rest is the captured selection.
Delete a file to delete an annotation.
