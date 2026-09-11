local config = require("neiltree.config")
local state = require("neiltree.state")
local tree = require("neiltree.tree")
local render = require("neiltree.render")
local actions = require("neiltree.actions")
local diff = require("neiltree.diff")
local apply = require("neiltree.apply")
local util = require("neiltree.util")
local watch = require("neiltree.watch")
local sidebar = require("neiltree.sidebar")

local M = {}

--- Install every highlight group the plugin renders with, as `default`
--- links so any colorscheme can override them. Public because the git panel
--- needs them installed too, and re-run from the ColorScheme autocmd below:
--- `:colorscheme` clears `default = true` links, so without that the tree's
--- colors silently fell back to Normal until the next `open()`.
function M.set_highlights()
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end

  link("NeiltreeDirIcon", "Directory")
  link("NeiltreeFileIcon", "Normal")
  link("NeiltreeDirName", "Directory")

  -- Git panel. `Added`/`Changed`/`Removed` and `DiagnosticError` are
  -- foreground-only groups, unlike `DiffAdd`/`DiffChange`/`ErrorMsg`, which
  -- carry a background in most colorschemes and would paint whole rows.
  link("NeiltreeGitHead", "Title")
  link("NeiltreeGitDetached", "WarningMsg")
  link("NeiltreeGitUpstream", "Comment")
  link("NeiltreeGitAhead", "Added")
  link("NeiltreeGitBehind", "Removed")
  link("NeiltreeGitSection", "Title")
  link("NeiltreeGitCount", "Comment")
  link("NeiltreeGitChevron", "Delimiter")
  link("NeiltreeGitBranch", "Normal")
  link("NeiltreeGitBranchCurrent", "Special")
  link("NeiltreeGitRemote", "Constant")
  link("NeiltreeGitStaged", "Added")
  link("NeiltreeGitUnstaged", "Changed")
  link("NeiltreeGitUntracked", "Comment")
  link("NeiltreeGitDeleted", "Removed")
  link("NeiltreeGitConflict", "DiagnosticError")
  link("NeiltreeGitHint", "Comment")
  link("NeiltreeGitError", "ErrorMsg")

  -- Commit graph. The lane colors are cycled by lane index, so they only
  -- have to be tellable apart from each other - these are the standard
  -- syntax groups every colorscheme gives a distinct color.
  link("NeiltreeGitLane1", "Function")
  link("NeiltreeGitLane2", "String")
  link("NeiltreeGitLane3", "Constant")
  link("NeiltreeGitLane4", "Identifier")
  link("NeiltreeGitLane5", "Type")
  link("NeiltreeGitLane6", "Statement")
  link("NeiltreeGitSubject", "Normal")
  link("NeiltreeGitAuthor", "Comment")
  link("NeiltreeGitDate", "Comment")
  link("NeiltreeGitSha", "Comment")
  link("NeiltreeGitTag", "Type")
  link("NeiltreeGitRefLocal", "Identifier")
  link("NeiltreeGitRefHead", "Special")
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

local function place_window(bufnr, opts)
  if opts.sidebar then
    -- One window per tabpage holds whichever neiltree view is showing (see
    -- sidebar.lua) - the tree and the git panel swap in and out of it
    -- rather than each opening a split of its own.
    return sidebar.place(bufnr)
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

--- Remember, for every window showing `st`'s buffer, its view and the path
--- of the entry the cursor is parked on - `restore_views` puts the cursor
--- back on that same entry after the rebuild, even if it has moved to a
--- different line (or, if it's gone from disk, leaves the cursor where it
--- was). Must run before `render.full` clears `st.mark_to_node`.
local function save_views(st)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(st.bufnr)) do
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    local node = actions.node_at_row(st, view.lnum - 1)
    saved[win] = { view = view, path = node and node.path }
  end
  return saved
end

local function restore_views(st, saved, order)
  local row_of_path = {}
  for row, node in ipairs(order) do
    row_of_path[node.path] = row
  end
  for win, entry in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == st.bufnr then
      local view = entry.view
      local new_lnum = entry.path and row_of_path[entry.path]
      if new_lnum and new_lnum ~= view.lnum then
        -- Scroll by the same amount the line moved, so an entry sitting
        -- mid-window stays put on screen instead of jumping to the top.
        view.topline = math.max(1, view.topline + (new_lnum - view.lnum))
        view.lnum = new_lnum
      end
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

function M.resync(st)
  local expanded_paths = {}
  collect_expanded_paths(st.root, expanded_paths)

  local saved = save_views(st)

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

  local order = render.full(st)
  restore_views(st, saved, order)

  st.stale = false
  st.stale_notified = false
  watch.sync(st)
end

--- Resync because *disk* changed, not because the user asked: triggered by
--- the directory watchers (watch.lua) and by the catch-up autocmds below.
--- Unlike `resync` this must never surprise anyone, so it bails out - and
--- leaves `st.stale` set for the next trigger to retry - whenever
--- rebuilding the buffer would destroy something: unsaved edits, a
--- half-finished insert/visual/operator, or an open command-line window
--- (where editing another buffer isn't even allowed).
function M.auto_refresh(st)
  if not st or not config.options.auto_refresh or not vim.api.nvim_buf_is_valid(st.bufnr) then
    return
  end
  if vim.bo[st.bufnr].modified then
    st.stale = true
    if not st.stale_notified then
      st.stale_notified = true
      vim.notify(
        ("[neiltree] the directory changed on disk - save, or press %s to refresh"):format(
          config.options.keymaps.refresh
        ),
        vim.log.levels.WARN
      )
    end
    return
  end
  if vim.fn.mode() ~= "n" or vim.fn.getcmdwintype() ~= "" then
    st.stale = true
    return
  end
  M.resync(st)
end

--- Rebuild every open tree buffer from disk, for the case where something
--- the user deliberately asked for - a branch switch from the git panel -
--- has just rewritten the working tree. Unlike `auto_refresh` this ignores
--- the `auto_refresh` setting (the user asked for the checkout, so they
--- expect the tree to follow) but it still refuses to throw work away:
--- a buffer with unsaved edits is only marked stale, for `:w`/`R` to catch
--- up on, exactly as a watcher-driven refresh would leave it.
function M.refresh_all_trees()
  if vim.fn.mode() ~= "n" or vim.fn.getcmdwintype() ~= "" then
    return
  end
  for bufnr, st in pairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        st.stale = true
      else
        M.resync(st)
      end
    end
  end
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

--- Preserve normal `dd` everywhere except for the one ambiguous tree edit
--- that cannot be left half-done: deleting an expanded directory's own
--- line while its descendants remain visible. In that case, remove the
--- rest of its visible subtree too and immediately run the normal save
--- flow. The existing confirmation therefore shows the recursive delete,
--- and a successful apply finishes with `resync()` as usual.
local function delete_lines(st)
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line_count = vim.api.nvim_buf_line_count(st.bufnr)
  local row1 = math.min(row0 + vim.v.count1 - 1, line_count - 1)
  local nodes = actions.nodes_in_range(st, row0, row1)
  local lines = vim.api.nvim_buf_get_lines(st.bufnr, 0, -1, false)
  local delete_to = row1
  local has_expanded = false

  -- Extend the normal counted line-delete through each selected expanded
  -- directory's contiguous, indented block. Reading the buffer indentation
  -- (instead of only walking known nodes) also removes a newly typed child
  -- line that has not received an identity extmark yet.
  for _, node in ipairs(nodes) do
    if node.type == "directory" and node.expanded then
      has_expanded = true
      local pos = vim.api.nvim_buf_get_extmark_by_id(st.bufnr, st.ns, node.mark_id, {})
      local scan = pos[1] + 1
      while scan < line_count do
        local line = lines[scan + 1]
        if line:match("%S") and #(line:match("^\t*") or "") <= node.depth then
          break
        end
        delete_to = math.max(delete_to, scan)
        scan = scan + 1
      end
    end
  end

  vim.cmd("normal! " .. (delete_to - row0 + 1) .. "dd")

  if not has_expanded then
    return
  end
  do_save(st)
end

--- Show `lines` in a small scratch float anchored at the cursor, dismissed
--- with `q`/<Esc>. Both this module's help and the git panel's use it.
function M.lines_float(lines)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
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
    "dd  delete (expanded directories ask to apply immediately)",
    km.refresh .. "  refresh from disk (discards unsaved edits)",
    ":w  save: create/rename/move/delete files to match the buffer",
    km.close .. " / <C-c>  close",
  }
  M.lines_float(lines)
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

  vim.keymap.set("n", "dd", function()
    delete_lines(st)
  end, opts)

  local function do_close()
    if st.sidebar and vim.api.nvim_get_current_win() == sidebar.get() then
      -- Close through the slot, so it is forgotten rather than left
      -- pointing at a dead window for the next toggle to trip over.
      if not sidebar.close() then
        vim.notify("[neiltree] save or discard changes before closing", vim.log.levels.WARN)
      end
      return
    end
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

  -- Insert-mode <C-w>/<C-u> swallow a whole run of whitespace in one press,
  -- and the leading tabs on a line here are *structure*, not text (one tab
  -- per tree level - see render.lua). Clearing a name with a couple of
  -- <C-w>s therefore used to take the indent with it once the name ran out,
  -- silently dedenting the entry: it jumps out to the parent directory on
  -- screen, and `:w` applies that as a move. Stop both at the end of the
  -- indent, so changing an entry's depth stays a deliberate edit (<BS>,
  -- <<, ...) instead of a side effect of erasing its name.
  local function stop_at_indent(key)
    return function()
      local line = vim.api.nvim_get_current_line()
      local indent = #(line:match("^\t*") or "")
      if vim.fn.col(".") - 1 <= indent then
        return ""
      end
      return key
    end
  end
  for _, lhs in ipairs({ "<C-w>", "<C-u>" }) do
    vim.keymap.set("i", lhs, stop_at_indent(lhs), { buffer = bufnr, expr = true, silent = true })
  end

  vim.keymap.set("n", km.help, function()
    show_help(st)
  end, opts)
end

-- Watchers don't fire everywhere: WSL's /mnt/... and network mounts have no
-- change notifications at all, and a deeply expanded tree can outrun the
-- watcher cap. These are the catch-up triggers - the moments a change made
-- outside this buffer has just plausibly happened - for every neiltree
-- buffer currently on screen, including a sidebar you weren't focused on.
local global_group
function M.ensure_global_autocmds()
  if global_group then
    return
  end
  global_group = vim.api.nvim_create_augroup("neiltree_auto_refresh", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = global_group,
    callback = function()
      M.set_highlights()
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave", "ShellCmdPost", "DirChanged" }, {
    group = global_group,
    callback = function()
      for bufnr, st in pairs(state.buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
          M.auto_refresh(st)
        end
      end
    end,
  })
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
  M.ensure_global_autocmds()
  watch.sync(st)

  -- Entering the buffer (or coming back to Neovim with the cursor already
  -- in it) is the other moment to catch up on anything the watchers missed;
  -- InsertLeave/CursorHold are the retries for a refresh that had to be
  -- deferred while you were mid-edit.
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "InsertLeave", "CursorHold" }, {
    buffer = bufnr,
    callback = function()
      M.auto_refresh(state.get(bufnr))
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      do_save(state.get(bufnr))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      local st_wiped = state.get(bufnr)
      if st_wiped then
        watch.detach(st_wiped)
      end
      state.clear(bufnr)
      sidebar.prune()
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
  M.set_highlights()
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
    sidebar.claim(vim.api.nvim_get_current_win())
  end
end

--- Toggle the file tree in the sidebar on the current tabpage. This is the
--- nerdtree/nvim-tree-style entry point - bind a single key to it.
---
--- Three outcomes, because the sidebar is a shared slot rather than a
--- tree-only window: showing the tree, this closes it; showing the git
--- panel, this swaps the tree back in (the two views trade places rather
--- than stacking); showing anything else - the user `:e`'d over it - the
--- slot is disowned and a fresh split opened, so their buffer is neither
--- hijacked nor closed out from under them.
function M.toggle_sidebar(path, opts)
  local buf = sidebar.buf()
  if buf then
    local ft = vim.bo[buf].filetype
    if ft == "neiltree" then
      if not sidebar.close() then
        vim.notify("[neiltree] save or discard changes before closing", vim.log.levels.WARN)
      end
      return
    elseif ft ~= "neiltreegit" then
      sidebar.release()
    end
  end
  M.open(path, vim.tbl_extend("force", opts or {}, { sidebar = true }))
end

return M
