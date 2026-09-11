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
- `--git` (`:Neiltree --git`, or `require("neiltree").toggle_git(path)`):
  the git panel - current branch, working-tree status and the branch
  lists - in that *same* sidebar window. The tree and the panel trade
  places rather than stacking, so one key each is enough. See
  "[Git panel](#git-panel)" below.
- `--graph` (`:Neiltree --graph`, or `require("neiltree").open_graph(path)`):
  the commit graph, in a centered float. See
  "[Commit graph](#commit-graph)" below.

| Key           | Action                                                     |
|---------------|--------------------------------------------------------------|
| `<CR>`        | Open file under cursor, or expand/collapse directory        |
| `l`           | Expand directory under cursor                                |
| `h`           | Collapse directory under cursor, or go up (see below)         |
| `-`           | Jump to parent line, or go up (see below)                     |
| `x`           | Cut (queue for move) - works on a visual line range too      |
| `p`           | Paste: move cut item(s) into the directory under the cursor  |
| `dd`          | Delete an entry; expanded directories ask to apply immediately |
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

## Git panel

`:Neiltree --git` toggles a read-only view of the local repository into the
sidebar - the same window the file tree uses, so the two swap places instead
of competing for room. Toggle it off and the tree you displaced comes back;
toggle the tree on and the panel steps aside.

```
 main                     ↑2 ↓1     <- HEAD, and how far it has drifted
 ↳ origin/main                         from its upstream

 ▾ Changes (1)
 M  lua/neiltree/ui.lua

 ▾ Untracked (1)
 ?  notes.md

 ▾ Local (3)
 *  main                     ≡      <- ≡ in sync, ↑ ahead, ↓ behind, ↕ both
    fix/insert-ctrl-w-eats-…
 +  wip/panel                       <- checked out in another worktree

 ▸ Remotes (12)
```

Everything comes from the plain `git` CLI - no network, no GitHub API, no
`gh`. The two-letter status codes are `git status -s`'s, staged column
first.

| Key    | Action                                                          |
|--------|-----------------------------------------------------------------|
| `<CR>` | on a branch, switch to it; on a file, open it; on a section header, fold/unfold |
| `l`    | unfold the section under the cursor                              |
| `h`    | fold it, or jump to the header from a row inside it              |
| `-`    | jump to the section header                                       |
| `R`    | re-read from git                                                 |
| `g?`   | help                                                             |
| `q`    | close the sidebar                                                |

The keys are the tree's own (`keymaps` in `setup()`), so remapping one
remaps it in both places.

**Switching branches** runs `git switch`, which needs git 2.23 or newer. A
clean working tree switches immediately; a dirty one asks first (that's
`confirm_changes`, the same setting that guards saves). Neither forces
anything - if git refuses because the switch would overwrite local changes,
you get git's own message and nothing happens. A branch already checked out
in another worktree is marked `+` and says so instead of failing. Selecting a
remote-only branch creates a local branch tracking it, always via the
fully-qualified `origin/name`, so two remotes owning the same branch name is
not ambiguous.

Because a branch switch rewrites files under you, a successful one runs
`:checktime` so buffers you already have open reload, and refreshes every
open tree. A buffer that is modified *and* changed on disk gets Vim's usual
"file changed" prompt rather than being quietly resolved either way.

The panel keeps itself current the same way the tree does: it watches the
git directory (and, in a linked worktree, the shared one where `refs/` really
lives) plus the repository root, and rescans on the same catch-up triggers -
entering it, regaining focus, `:!cmd`, leaving a `:terminal`, saving a
buffer. Those watches are non-recursive, so a file changed deep in the tree
by another program shows up at the next catch-up rather than instantly;
`R` always forces it. `auto_refresh = false` turns the automatic half off.

Sections cap at `git.max_rows` rendered rows (200 by default) with a
selectable `… N more`, so a repository with thousands of branches stays
usable; the counts in the headers are always the real ones. Remotes start
folded (`git.remotes_collapsed`).

Outside a repository, `--git` says so and changes nothing - it will not
replace a file tree you have open with an error.

## Commit graph

`:Neiltree --graph` draws the commit DAG - dots for commits, lines for the
relationships between them - the way VS Code's graph does, with branch and
tag names as inline badges.

```
 ●   main v1.0 origin/main  release prep        ray    2h   d80f5af3
 ●╮  Merge branch 'fix/watcher'                 ray    2h   6b7bddc6
 │●  fix/watcher  watch git dir                 ray    3h   87a66d76
 ●│  tidy up                                    ray    3h   cc87322b
 ●┼╮ Merge branch 'feature/panel'               ray    4h   a2d1a398
 ││● feature/panel  panel render                ray    4h   cd2398aa
 ││● panel skeleton                             ray    4h   f377cd4e
 ●╯│ fix indent bug                             ray    5h   fcf4b8a1
 ●─╯ add parser                                 ray    6h   66ba0d33
```

**Exactly one row per commit.** This is not `git log --graph`, which spends
extra rows on edge transitions (the `|\` and `|/` lines) - there, a row is
often not a commit at all, so a cursor cannot be mapped back to one. Here
every row is a commit you can select, and edges turn within that same row.
Lanes are colored by column so parallel branches stay tellable apart.

A **float rather than the sidebar**, because a graph is mostly horizontal:
lanes, refs, subject, author, age and hash do not fit in a 30-column split,
and dropping any of them is what makes a narrow graph useless. The sidebar
panel is unchanged and the two are independent - you can have both open.
As the window narrows the author column goes first, then the age; the graph
and the subject are always kept.

| Key           | Action                                          |
|---------------|-------------------------------------------------|
| `<CR>`        | switch to the branch on this commit             |
| `R`           | re-read from git                                |
| `q` / `<Esc>` | close                                           |
| `g?`          | help                                            |

`<CR>` switches branches through the same path as the panel, so the same
confirmations and the same `:checktime` reload apply. A commit with no
branch on it says so rather than detaching. A commit carrying several
branches asks which - except that a local branch and its own
remote-tracking ref sitting together (`main` and `origin/main`, much the
commonest case) count as one destination, not two.

Reads `git.graph_limit` commits (500 by default) across all refs; the last
row offers to double that. Ages are compacted to `17m` / `3d` / `2y` -
git's own relative dates are the most readable form for browsing history
and the least predictable width, and the column that buys back goes to the
commit subject.

## Editing rules

- **Rename**: edit the name in place (`ciw`, `cw`, individual character
  edits...). Don't delete the whole line and retype it - see below.
- **Create a file**: type a new line. A trailing `/` makes it a directory.
  A name with an embedded `/` (e.g. `sub/new.txt`) creates the
  intermediate directory too.
- **Delete**: delete the line (`dd`). On an expanded directory, `dd` also
  removes its visible descendants from the buffer and immediately opens the
  usual save confirmation; confirming recursively deletes it from disk and
  refreshes the tree. Files and collapsed directories remain ordinary
  pending edits until `:w`.
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
