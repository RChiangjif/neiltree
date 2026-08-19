local config = require("neiltree.config")
local state = require("neiltree.state")
local tree = require("neiltree.tree")
local render = require("neiltree.render")
local actions = require("neiltree.actions")
local diff = require("neiltree.diff")
local apply = require("neiltree.apply")
local util = require("neiltree.util")

local M = {}

local function set_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "NeiltreeDirIcon", { link = "Directory", default = true })
  set(0, "NeiltreeFileIcon", { link = "Normal", default = true })
  set(0, "NeiltreeDirName", { link = "Directory", default = true })
end

local function buf_name(path)
  return "neiltree://" .. path
end

--- Exact-match buffer lookup by name, or -1. `vim.fn.bufnr(name)` treats
--- `name` as a regex/glob pattern rather than a literal string, so e.g.
--- looking up "neiltree:///a/proj" would wrongly match an already-open
--- "neiltree:///a/proj/src" (the shorter name matches as a substring) -
--- exactly the case `go_up` hits stepping from a subdirectory up to its
--- parent.
local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

--- Open `bufnr` in a centered floating window, oil.nvim `--float`-style,
--- instead of taking over the current split.
local function open_floating(bufnr)
  local width = math.min(math.floor(vim.o.columns * 0.9), 120)
  local height = math.min(math.floor(vim.o.lines * 0.9), 40)
  return vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  })
end

--- Open `bufnr` in a fixed-width vertical split pinned to one edge of the
--- tabpage, nerdtree/nvim-tree-style, and set the usual sidebar window
--- options (no numbers/signcolumn, doesn't get squeezed by `wincmd =`).
local function open_sidebar(bufnr)
  local side = config.options.sidebar_side == "right" and "botright" or "topleft"
  vim.cmd(("%s vertical %d split"):format(side, config.options.sidebar_width))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  return win
end

-- tabpage handle -> sidebar window id, so a second `toggle_sidebar` call
-- (or a second `--sidebar` open) knows to close the existing one instead
-- of stacking another.
local sidebar_wins = {}

local function place_window(bufnr, opts)
  if opts.sidebar then
    local win = open_sidebar(bufnr)
    sidebar_wins[vim.api.nvim_get_current_tabpage()] = win
    return win
  end
  if opts.float then
    return open_floating(bufnr)
  end
  vim.api.nvim_win_set_buf(0, bufnr)
  return vim.api.nvim_get_current_win()
end

local function collect_expanded_paths(node, set)
  if not node.children then
    return
  end
  for _, child in ipairs(node.children) do
    if child.expanded then
      set[child.path] = true
      collect_expanded_paths(child, set)
    end
  end
end

--- Rebuild the in-memory tree from disk, re-expanding whichever
--- directories were expanded before, then re-render the whole buffer.
--- This is the single source of truth for "make the buffer match disk" -
--- used after a successful save, and for a manual refresh.
--- Resync, but if the buffer has other unsaved edits (e.g. a pending
--- rename typed elsewhere), ask first - resync rebuilds every line from
--- disk, so it would otherwise silently discard them. Returns whether the
--- resync actually happened.
function M.confirm_and_resync(st)
  if vim.bo[st.bufnr].modified then
    if vim.fn.confirm("neiltree: this discards other unsaved edits in the buffer - continue?", "&Yes\n&No", 2) ~= 1 then
      return false
    end
  end
  M.resync(st)
  return true
end

function M.resync(st)
  local expanded_paths = {}
  collect_expanded_paths(st.root, expanded_paths)

  st.root = tree.new_root(st.root.path)
  tree.load_children(st.root)

  local function expand_matching(node)
    for _, child in ipairs(node.children) do
      if child.type == "directory" and expanded_paths[child.path] then
        child.expanded = true
        tree.load_children(child)
        expand_matching(child)
      end
    end
  end
  expand_matching(st.root)

  render.full(st)
end

local function do_save(st)
  local ops, errors = diff.compute(st)
  if not ops then
    vim.notify("[neiltree] cannot save:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end

  if #ops.deletes == 0 and #ops.moves == 0 and #ops.creates == 0 then
    vim.bo[st.bufnr].modified = false
    return
  end

  local summary = apply.summarize(ops)

  local proceed = true
  if config.options.confirm_changes then
    local msg = "neiltree: apply these changes?\n\n  " .. table.concat(summary, "\n  ")
    proceed = vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
  end

  if not proceed then
    vim.notify("[neiltree] save cancelled, buffer left modified", vim.log.levels.WARN)
    return
  end

  local run_errors = apply.run(ops)
  M.resync(st)

  if #run_errors > 0 then
    vim.notify("[neiltree] some changes failed:\n  " .. table.concat(run_errors, "\n  "), vim.log.levels.ERROR)
  else
    vim.notify(("[neiltree] applied %d change(s)"):format(#summary), vim.log.levels.INFO)
  end
end

local function show_help(st)
  local km = config.options.keymaps
  local lines = {
    "neiltree",
    "",
    km.select .. "  open file / toggle directory",
    km.expand .. "  expand directory",
    km.collapse .. "  collapse directory / go to parent (or up a dir, at the top)",
    km.parent_dir .. "  jump to parent line, or up a dir if already at the top",
    km.cut .. "  cut (queue for move); also works in visual mode",
    km.paste .. "  paste: move cut item(s) into dir under cursor",
    km.refresh .. "  refresh from disk (discards unsaved edits)",
    ":w  save: create/rename/move/delete files to match the buffer",
    km.close .. " / <C-c>  close",
  }
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width + 2,
    height = #lines,
    style = "minimal",
    border = "rounded",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf })
end

local function setup_keymaps(st)
  local bufnr = st.bufnr
  local km = config.options.keymaps
  local opts = { buffer = bufnr, silent = true, nowait = true }

  vim.keymap.set("n", km.select, function()
    local node = actions.node_at_cursor(st)
    if node then
      actions.select(st, node)
    end
  end, opts)

  vim.keymap.set("n", km.expand, function()
    local node = actions.node_at_cursor(st)
    if node then
      actions.expand(st, node)
    end
  end, opts)

  vim.keymap.set("n", km.collapse, function()
    local node = actions.node_at_cursor(st)
    if not node then
      M.go_up(st)
      return
    end
    if node.type == "directory" and node.expanded then
      actions.collapse(st, node)
    elseif not actions.goto_parent(st, node) then
      M.go_up(st)
    end
  end, opts)

  -- oil.nvim-style "up": jump to the parent line if `node` has one visible
  -- in the tree, otherwise re-root the whole buffer one directory up.
  vim.keymap.set("n", km.parent_dir, function()
    local node = actions.node_at_cursor(st)
    if not node or not actions.goto_parent(st, node) then
      M.go_up(st)
    end
  end, opts)

  vim.keymap.set("n", km.cut, function()
    local node = actions.node_at_cursor(st)
    if node then
      actions.cut(st, { node })
    end
  end, opts)

  vim.keymap.set("x", km.cut, function()
    local row0 = vim.fn.line("v") - 1
    local row1 = vim.fn.line(".") - 1
    if row0 > row1 then
      row0, row1 = row1, row0
    end
    vim.cmd("normal! \27") -- leave visual mode
    local nodes = actions.nodes_in_range(st, row0, row1)
    if #nodes > 0 then
      actions.cut(st, nodes)
    end
  end, opts)

  vim.keymap.set("n", km.paste, function()
    actions.paste(st)
  end, opts)

  vim.keymap.set("n", km.refresh, function()
    M.confirm_and_resync(st)
  end, opts)

  local function do_close()
    if st.float or st.sidebar then
      if not pcall(vim.api.nvim_win_close, 0, false) then
        vim.notify("[neiltree] save or discard changes before closing", vim.log.levels.WARN)
      end
      return
    end
    if not pcall(vim.cmd, "buffer #") then
      vim.cmd("bdelete " .. bufnr)
    end
  end

  vim.keymap.set("n", km.close, do_close, opts)
  -- <C-c>/<Esc> are float-only quick-dismiss aliases for `close` - a
  -- sidebar is meant to stay put like nvim-tree/nerdtree, so a stray
  -- Ctrl-C or Escape while working in it must not close it; `q` (or
  -- toggling it again from outside) is the deliberate way to close one.
  for _, lhs in ipairs({ "<C-c>", "<Esc>" }) do
    if km.close ~= lhs then
      vim.keymap.set("n", lhs, function()
        if st.float then
          do_close()
        end
      end, opts)
    end
  end

  vim.keymap.set("n", km.help, function()
    show_help(st)
  end, opts)
end

--- Get (or create) the neiltree buffer rooted at `path`, without touching
--- any window. Split out of `M.open` so `M.go_up` can swap the *current*
--- window's buffer directly instead of placing a brand new window the way
--- a fresh `open()` would.
local function get_or_create_buffer(path, opts)
  local name = buf_name(path)
  local existing = find_buf_by_name(name)
  if existing ~= -1 then
    return existing, false
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = "neiltree"
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = ""
  -- Guaranteed on regardless of the user's own settings: pressing `o`/`O`
  -- to add a new entry should default to the same depth as the line you
  -- were on (a sibling), letting you type extra tabs to nest it deeper
  -- instead of having to retype the whole indent by hand.
  vim.bo[bufnr].autoindent = true
  -- Depth is one literal tab character per level (see render.lua) - a real
  -- <Tab> keypress must insert a tab, not spaces, and it should render
  -- narrow rather than the usual 8-wide default.
  vim.bo[bufnr].expandtab = false
  vim.bo[bufnr].tabstop = 2
  -- 0 defers to 'tabstop'. A mismatched shiftwidth combined with the
  -- (Nvim-default-on) 'smarttab' makes <Tab> at the start of a line insert
  -- shiftwidth-worth of *spaces* instead of a real tab whenever the two
  -- don't line up - keeping them equal is what makes <Tab> reliably insert
  -- one literal tab character.
  vim.bo[bufnr].shiftwidth = 0

  local st = state.new(bufnr, path)
  tree.load_children(st.root)
  if opts.expand_all then
    tree.expand_all(st.root)
  end
  render.full(st)

  setup_keymaps(st)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      do_save(state.get(bufnr))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      state.clear(bufnr)
      for tab, win in pairs(sidebar_wins) do
        if not vim.api.nvim_win_is_valid(win) then
          sidebar_wins[tab] = nil
        end
      end
    end,
  })
  return bufnr, true
end

--- Open (or focus, if already open) a neiltree buffer rooted at `path`.
--- By default this takes over the current window, same as oil.nvim's
--- default. Pass `{ float = true }` (or use `:Neiltree --float`) for a
--- centered floating window on top of your layout instead, like
--- `:Oil --float`; pass `{ sidebar = true }` (or `:Neiltree --sidebar`,
--- or `M.toggle_sidebar()`) for a fixed-width nerdtree/nvim-tree-style
--- split pinned to one edge instead.
function M.open(path, opts)
  opts = vim.tbl_extend("force", { expand_all = config.options.expand_all, float = false, sidebar = false }, opts or {})
  set_highlights()
  path = util.abspath(path or vim.uv.cwd())
  local parent_win = vim.api.nvim_get_current_win()

  local bufnr = get_or_create_buffer(path, opts)
  local st = state.get(bufnr)
  st.float = opts.float
  st.sidebar = opts.sidebar
  st.parent_win = parent_win

  place_window(bufnr, opts)
end

--- Re-root the tree one directory up from wherever `st` is currently
--- rooted, replacing it in the *same* window it's already shown in
--- (float/sidebar/normal alike) - oil.nvim's `-`-at-the-top behavior,
--- extended to "up past the root" for a buffer that can already show an
--- arbitrarily deep subtree in place.
function M.go_up(st)
  local parent_path = vim.fs.dirname(st.root.path)
  if not parent_path or parent_path == st.root.path then
    vim.notify("[neiltree] already at the filesystem root", vim.log.levels.WARN)
    return
  end
  local was_float, was_sidebar, parent_win = st.float, st.sidebar, st.parent_win
  local bufnr = get_or_create_buffer(parent_path, { expand_all = config.options.expand_all })
  local new_st = state.get(bufnr)
  new_st.float = was_float
  new_st.sidebar = was_sidebar
  new_st.parent_win = parent_win
  vim.api.nvim_win_set_buf(0, bufnr)
  if was_sidebar then
    sidebar_wins[vim.api.nvim_get_current_tabpage()] = vim.api.nvim_get_current_win()
  end
end

--- Toggle the sidebar for `path` (default cwd) on the current tabpage:
--- closes it if one is already open here, opens one otherwise. This is
--- the nerdtree/nvim-tree-style entry point - bind a single key to it.
function M.toggle_sidebar(path, opts)
  local tab = vim.api.nvim_get_current_tabpage()
  local win = sidebar_wins[tab]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, false)
    sidebar_wins[tab] = nil
    return
  end
  M.open(path, vim.tbl_extend("force", opts or {}, { sidebar = true }))
end

return M
