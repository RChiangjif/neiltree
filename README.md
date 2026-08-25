# neiltree.nvim

An [oil.nvim](https://github.com/stevearc/oil.nvim)-style editable directory
buffer, extended to a recursive tree: expand any subdirectory in place and
edit files anywhere under the root, not just the top level.

- **Edit the filesystem as text.** Rename a file, and saving renames it on
  disk. Delete a line, and saving deletes that file. Type a new line, and
  saving creates it. This works across the whole expanded tree, not just
  one directory.
- **Expand subdirectories in place**, indented, in the same buffer - like
  netrw's tree mode, but editable.
- **Cross-directory moves** are a dedicated cut/paste action (`x` / `p`,
  works on a visual selection too), not something inferred from a text
  diff - see "Why cut/paste is separate" below.
- Every destructive save shows a confirmation prompt listing exactly what
  will be created/moved/deleted before touching disk.

## Install (lazy.nvim)

```lua
{
  dir = "~/proj/neiltree", -- or a git url once you push it somewhere
  name = "neiltree.nvim",
  lazy = false,
  dependencies = { "nvim-tree/nvim-web-devicons" }, -- optional, for file icons
  opts = {},
}
```

`opts` is passed to `require("neiltree").setup()`; see defaults in
`lua/neiltree/config.lua`.

## Usage

`:Neiltree [path]` opens a recursive, editable tree rooted at `path`
(default: cwd) in the current window, same as oil.nvim's default. Two
other ways to open it, and all three can be bound to different keys and
used side by side:

- `--float` (`:Neiltree --float`, or `require("neiltree").open(path, { float = true })`):
  a centered floating window on top of your layout, like `:Oil --float`.
  Leaves your splits untouched and closes itself when you pick a file.
- `--sidebar` (`:Neiltree --sidebar`, or `require("neiltree").toggle_sidebar(path)`):
  a fixed-width split pinned to one edge, nerdtree/nvim-tree-style. The
  same key toggles it closed again; picking a file opens it in whatever
  window you came from (splitting one off if the sidebar is the only
  window there is) and leaves the sidebar open. Width/side are
  `sidebar_width` / `sidebar_side` in `setup()`.

| Key           | Action                                                     |
|---------------|--------------------------------------------------------------|
| `<CR>`        | Open file under cursor, or expand/collapse directory        |
| `l`           | Expand directory under cursor                                |
| `h`           | Collapse directory under cursor, or go up (see below)         |
| `-`           | Jump to parent line, or go up (see below)                     |
| `x`           | Cut (queue for move) - works on a visual line range too      |
| `p`           | Paste: move cut item(s) into the directory under the cursor  |
| `R`           | Refresh from disk (asks first if you have unsaved edits) - rarely needed, see auto-refresh |
| `g?`          | Help                                                          |
| `q`           | Close (float/sidebar: closes the window; default: back to your previous buffer) |
| `<C-c>`/`<Esc>` | Quick-dismiss, **float only** - a sidebar is meant to stay put (nvim-tree-style), so these don't close it; use `q` or toggle it again |
| `:w`          | Apply pending create/rename/delete edits to disk             |

**Going up a directory**: `h`/`-` jump to the parent *line* when the entry
under the cursor has one visible in the tree. On a top-level entry (or
with nothing under the cursor) they instead re-root the whole buffer one
directory up - like oil.nvim's `-` - in the same window and the same
placement mode (float stays float, sidebar stays sidebar).

`<CR>`/select on a file whose extension is in `external_extensions`
(images, video, audio, pdf by default) opens it with the OS's default
application instead of loading it into a buffer, so e.g. `.png` doesn't
show up as garbage text. Customize the list in `setup()`.

Directories start collapsed; expand on demand with `l`/`<CR>`. Set
`expand_all = true` to open with every directory already expanded instead.
Either way, only expanded directories are ever touched by save - if you
haven't looked inside a directory, neiltree won't touch it.

## Staying in sync with disk

The tree keeps itself up to date: every directory it currently shows is
watched, so a file created, renamed or deleted by anything else - another
Neovim, a `git checkout`, a build, a shell in another window - appears (or
disappears) in the buffer on its own, with your cursor left on the same
entry it was on. As a backstop for filesystems that have no change
notifications (network mounts, `/mnt/...` under WSL) it also rescans when
you enter the tree buffer, when Neovim regains focus, and after `:!cmd` or
leaving a `:terminal`.

An automatic refresh rebuilds every line, so it never runs while that
would throw work away: if the buffer has unsaved edits it warns once and
holds off (save, or press `R`, and it catches up), and it waits until
you're back in normal mode rather than yanking lines around mid-edit.

Set `auto_refresh = false` in `setup()` for the old manual-only behavior.

## Editing rules

- **Rename**: edit the name in place (`ciw`, `cw`, individual character
  edits...). Don't delete the whole line and retype it - see below.
- **Create a file**: type a new line. A trailing `/` makes it a directory.
  A name with an embedded `/` (e.g. `sub/new.txt`) creates the
  intermediate directory too.
- **Delete**: delete the line (`dd`). Deleting a directory's line deletes
  it and everything inside it recursively - if the directory is expanded
  and some of its contents are still visible in the buffer below it,
  neiltree refuses to save and asks you to delete or move those out
  first, rather than guessing what you meant.
- **Reparent by dedent/indent**: changing a line's indentation to attach
  it under a *different* nearby directory (one already positioned
  correctly above it) is honored on save, as a rename.
- **Move to an unrelated directory elsewhere in the tree**: use cut (`x`)
  / paste (`p`) - see below for why.
- Depth is one literal tab character per level - `<Tab>` inserts a real
  tab in a neiltree buffer regardless of your global `expandtab`. Mixing
  in spaces for indentation is rejected on save.
  Because that indent is structure rather than text, insert-mode `<C-w>`
  and `<C-u>` stop at the end of it instead of swallowing it - erasing a
  name to retype it can't silently reparent the entry. Dedent
  deliberately with `<BS>` or `<<`.

### Why cut/paste is separate

Neovim only tells a plugin "this text was deleted" when the underlying
bytes are gone - it can't tell "I deleted this to retype it in place" apart
from "I deleted this and I'm about to paste something unrelated a few
lines down". So a cut-line-and-paste-elsewhere edit is indistinguishable,
at save time, from delete-this-file-then-create-a-new-one-with-the-same-name
- which would silently destroy the contents of anything but an empty file.

Rather than get that wrong, moving to a non-adjacent part of the tree is
its own explicit action (`x` / `p`) that runs immediately against the
filesystem, the same way a file manager's cut/paste does, instead of being
inferred from a buffer diff on `:w`.

## Known limitations

- Swap-renames (`a -> b` and `b -> a` in the same save) aren't supported.
- Moving across filesystems/mount points (or into a path that already
  exists) will fail with an error from the underlying `rename(2)`/`mkdir`
  call; neiltree reports it and leaves the rest of the batch applied.
