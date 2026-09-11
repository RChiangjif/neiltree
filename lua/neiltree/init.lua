local config = require("neiltree.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

--- Open a neiltree buffer rooted at `path` (default: cwd) in the current
--- window. Directories start collapsed; press the `expand` keymap (default
--- `l`) or `<CR>` on a directory to reveal its contents in place. Pass
--- `{ expand_all = true }` (or set it in `setup()`) to open with every
--- directory already expanded instead.
function M.open(path, opts)
  require("neiltree.ui").open(path, opts)
end

--- Toggle a nerdtree/nvim-tree-style sidebar for `path` (default: cwd) on
--- the current tabpage: closes it if one's already open here, opens one
--- otherwise. Bind this to a key for an always-available tree, alongside
--- `open()` / `{ float = true }` for one-off lookups.
function M.toggle_sidebar(path, opts)
  require("neiltree.ui").toggle_sidebar(path, opts)
end

--- Toggle the git panel for `path` (default: whatever the sidebar is already
--- rooted at, else the current file's directory, else cwd) in the same
--- sidebar slot the file tree uses on this tabpage. Shows the current
--- branch and its upstream tracking, the working-tree status, and the local
--- and remote branch lists, all from the plain `git` CLI; select a branch to
--- switch to it. The tree and the panel share one window - toggling either
--- swaps the other out, and toggling this one off puts the tree back.
function M.toggle_git(path, opts)
  require("neiltree.gitpanel").toggle(path, opts)
end

--- Open the commit graph for `path` (default: the same repo `toggle_git`
--- would pick) in a centered float: the commit DAG drawn one row per commit,
--- with branch and tag names as inline badges. Select a commit carrying a
--- branch to switch to it. A float rather than the sidebar because a graph
--- needs horizontal room - lanes, refs, subject, author, date and hash do
--- not fit in a 30-column split.
function M.open_graph(path, opts)
  require("neiltree.graphview").open(path, opts)
end

return M
