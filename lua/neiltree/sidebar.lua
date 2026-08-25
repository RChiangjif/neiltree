local config = require("neiltree.config")

local M = {}

--- tabpage handle -> the window acting as that tab's neiltree sidebar.
--- Both views that can live there - the editable file tree and the git
--- panel - share this one window, one at a time, so switching between them
--- is a buffer swap rather than a second split.
local wins = {}

--- The window options a sidebar always gets: no numbers/signcolumn, no
--- wrapping, and immune to `wincmd =`. These must be re-applied on every
--- buffer swap, not just when the split is created: Neovim keeps
--- window-local options per (window, buffer) pair and restores the old set
--- whenever a buffer returns to a window it previously occupied.
local function apply_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
end

--- The sidebar window for `tab` (default: the current tabpage), or nil.
--- Self-pruning: an entry whose window has been closed, or dragged to
--- another tabpage with `<C-w>T`, is forgotten rather than reported.
function M.get(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local win = wins[tab]
  if not win then
    return nil
  end
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_tabpage(win) ~= tab then
    wins[tab] = nil
    return nil
  end
  return win
end

--- The buffer currently sitting in the sidebar, or nil. Callers branch on
--- its 'filetype' ("neiltree" / "neiltreegit") to decide what a toggle
--- means, since "the window is still valid" no longer implies "it still
--- holds one of ours" - the user may simply have `:e`'d something else
--- into it.
function M.buf(tab)
  local win = M.get(tab)
  return win and vim.api.nvim_win_get_buf(win) or nil
end

--- Record `win` as the sidebar, for callers that swapped a buffer into the
--- window they were already in (see `ui.go_up`).
function M.claim(win, tab)
  wins[tab or vim.api.nvim_get_current_tabpage()] = win
end

--- Forget the sidebar without closing its window - used when the user has
--- put something of their own in it, so a later toggle opens a fresh split
--- instead of hijacking (or closing) their buffer.
function M.release(tab)
  wins[tab or vim.api.nvim_get_current_tabpage()] = nil
end

--- Drop every entry whose window is gone.
function M.prune()
  for tab, win in pairs(wins) do
    if not vim.api.nvim_win_is_valid(win) then
      wins[tab] = nil
    end
  end
end

--- Put `bufnr` in the sidebar: swap it into the existing sidebar window if
--- there is one, otherwise open the fixed-width split. Reuse deliberately
--- does not resize - a sidebar the user has dragged wider stays that width.
--- Returns the window, or nil if Neovim refused the swap (only possible
--- with 'nohidden' and unsaved edits in the outgoing buffer).
function M.place(bufnr, opts)
  opts = opts or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local win = M.get(tab)

  if win then
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, bufnr)
    if not ok then
      vim.notify("[neiltree] cannot replace the sidebar buffer: " .. tostring(err), vim.log.levels.ERROR)
      return nil
    end
  else
    local side = config.options.sidebar_side == "right" and "botright" or "topleft"
    vim.cmd(("%s vertical %d split"):format(side, config.options.sidebar_width))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    wins[tab] = win
  end

  apply_win_opts(win)
  if opts.focus ~= false then
    vim.api.nvim_set_current_win(win)
  end
  return win
end

--- Close the sidebar window. Returns false if Neovim refused (it was the
--- last window, or the buffer has unsaved edits it won't abandon).
function M.close(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local win = M.get(tab)
  if not win then
    return true
  end
  if not pcall(vim.api.nvim_win_close, win, false) then
    return false
  end
  wins[tab] = nil
  return true
end

--- Move out of the sidebar into the window a file should be opened in: the
--- previously active one, or a fresh vertical split when the sidebar is the
--- only window there is. Shared by the file tree's `select` and the git
--- panel's "open this changed file", so the two can't drift apart.
function M.leave_to_edit_win()
  local from = vim.api.nvim_get_current_win()
  vim.cmd("wincmd p")
  if vim.api.nvim_get_current_win() == from then
    vim.cmd("vsplit")
  end
end

return M
