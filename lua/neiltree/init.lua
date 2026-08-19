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

return M
