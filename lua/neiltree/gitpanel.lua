local config = require("neiltree.config")
local git = require("neiltree.git")
local sidebar = require("neiltree.sidebar")
local util = require("neiltree.util")

local M = {}

local uv = vim.uv

-- A branch switch rewrites hundreds of files and the index several times
-- over, so this sits well above watch.lua's 100ms.
local DEBOUNCE_MS = 250

--- repo root -> panel. Deliberately *not* `state.buffers`: ui.lua's global
--- refresh sweep walks that table calling `resync()` on every entry, which
--- assumes a file-tree state and would blow up on a panel.
local panels = {}
--- Exposed for poking at from `:lua` - there is no test harness in this repo.
M._panels = panels

local ns = vim.api.nvim_create_namespace("neiltree_git")

local NERD = { open = "▾", closed = "▸", up = "↑", down = "↓", sync = "≡", diverged = "↕", arrow = "↳", ellipsis = "…" }
local ASCII = { open = "v", closed = ">", up = "+", down = "-", sync = "=", diverged = "~", arrow = "->", ellipsis = "..." }

--- Reuses the existing `icons` option rather than adding a second one: a
--- terminal without a Nerd Font has the same problem with both.
local function sym()
  return config.options.icons and NERD or ASCII
end

-- ---------------------------------------------------------------- rendering

--- A line under construction: its text so far, plus the highlight spans
--- accumulated as byte offsets. Building lines out of `put` segments is what
--- keeps `col`/`end_col` correct for free across multi-byte glyphs, which a
--- multi-column panel full of arrows and chevrons is otherwise easy to get
--- subtly wrong.
local function newline()
  return { text = "", marks = {} }
end

local function put(l, text, hl)
  if text ~= "" then
    if hl then
      table.insert(l.marks, { col = #l.text, end_col = #l.text + #text, hl = hl })
    end
    l.text = l.text .. text
  end
  return l
end

--- Pad `l` so a `tail_cells`-wide tail lands flush against `width`.
local function pad_to(l, width, tail_cells)
  local gap = width - vim.fn.strdisplaywidth(l.text) - tail_cells
  return put(l, string.rep(" ", math.max(gap, 1)))
end

--- Shrink `s` to at most `cells` *display columns*. `mode` "tail" keeps the
--- start and marks the cut at the end - right for branch names, whose
--- prefixes (`fix/`, `feat/`, `user/`) are how you scan a list. "head" keeps
--- the end - right for paths, where the basename is the discriminator.
--- Display-cell rather than byte arithmetic, since branch names and paths
--- are routinely non-ASCII.
local function truncate(s, cells, mode)
  if cells <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= cells then
    return s
  end
  local mark = sym().ellipsis
  local budget = cells - vim.fn.strdisplaywidth(mark)
  if budget <= 0 then
    return ""
  end
  local n = vim.fn.strchars(s)
  if mode == "head" then
    for i = 1, n do
      local part = vim.fn.strcharpart(s, i)
      if vim.fn.strdisplaywidth(part) <= budget then
        return mark .. part
      end
    end
    return mark
  end
  for len = n, 1, -1 do
    local part = vim.fn.strcharpart(s, 0, len)
    if vim.fn.strdisplaywidth(part) <= budget then
      return part .. mark
    end
  end
  return mark
end

--- Render against the window's real width, not `sidebar_width`: a sidebar
--- the user dragged wider should use the room.
local function panel_width(panel)
  local wins = vim.fn.win_findbuf(panel.bufnr)
  if #wins > 0 then
    return vim.api.nvim_win_get_width(wins[1])
  end
  return config.options.sidebar_width
end

local function track_glyph(track)
  local S = sym()
  if track == ">" then
    return S.up, "NeiltreeGitAhead"
  elseif track == "<" then
    return S.down, "NeiltreeGitBehind"
  elseif track == "<>" then
    return S.diverged, "NeiltreeGitBehind"
  elseif track == "=" then
    return S.sync, "NeiltreeGitUpstream"
  end
  return "", nil
end

--- The status sections, in the order git itself reports them. Empty status
--- sections are omitted entirely - "Staged (0)" in a 30-column panel is
--- noise - while the branch sections always render, so their headers stay
--- available to fold.
local function sections(panel)
  local d = panel.data
  local out = {}
  if not d.bare then
    local status = {
      { id = "conflicts", label = "Conflicts", items = d.conflicts, hl = "NeiltreeGitConflict" },
      { id = "staged", label = "Staged", items = d.staged, hl = "NeiltreeGitStaged" },
      { id = "unstaged", label = "Changes", items = d.unstaged, hl = "NeiltreeGitUnstaged" },
      { id = "untracked", label = "Untracked", items = d.untracked, hl = "NeiltreeGitUntracked" },
    }
    for _, sec in ipairs(status) do
      if #sec.items > 0 then
        sec.kind = "file"
        table.insert(out, sec)
      end
    end
  end
  table.insert(out, { id = "locals", label = "Local", items = d.locals, kind = "branch" })
  table.insert(out, { id = "remotes", label = "Remotes", items = d.remotes, kind = "remote" })
  return out
end

--- A row's stable identity across a rebuild, so the cursor can be put back
--- on the same *item* rather than the same line number.
local function row_key(item)
  if not item then
    return nil
  end
  return item.kind .. ":" .. (item.name or item.path or item.id or "")
end

local function save_views(panel)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(panel.bufnr)) do
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    saved[win] = { view = view, key = row_key(panel.rows[view.lnum]) }
  end
  return saved
end

local function restore_views(panel, saved)
  local row_of = {}
  for i, item in pairs(panel.rows) do
    local key = row_key(item)
    if key and not row_of[key] then
      row_of[key] = i
    end
  end
  local last = math.max(vim.api.nvim_buf_line_count(panel.bufnr), 1)
  for win, entry in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == panel.bufnr then
      local view = entry.view
      local lnum = entry.key and row_of[entry.key]
      if lnum and lnum ~= view.lnum then
        -- Same trick as ui.restore_views: scroll by however far the row
        -- moved, so an item sitting mid-window stays put on screen.
        view.topline = math.max(1, view.topline + (lnum - view.lnum))
        view.lnum = lnum
      end
      view.lnum = math.min(math.max(view.lnum, 1), last)
      view.topline = math.min(math.max(view.topline, 1), last)
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

local function render(panel)
  if not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end
  local S = sym()
  local width = panel_width(panel)
  local saved = save_views(panel)
  local lines, marks, rows = {}, {}, {}

  local function emit(l, item)
    table.insert(lines, l.text)
    for _, m in ipairs(l.marks) do
      table.insert(marks, { #lines - 1, m.col, m.end_col, m.hl })
    end
    if item then
      rows[#lines] = item
    end
  end

  local function hint(text)
    emit(put(newline(), text, "NeiltreeGitHint"))
  end

  if panel.busy then
    emit(put(newline(), " " .. S.ellipsis .. " " .. truncate(panel.busy, width - 3, "tail"), "NeiltreeGitHint"))
  end

  if panel.err then
    emit(put(newline(), " " .. truncate(panel.err, width - 1, "tail"), "NeiltreeGitError"))
    hint(" press " .. config.options.keymaps.refresh .. " to retry")
  elseif not panel.data then
    hint(" " .. S.ellipsis .. " loading")
  else
    local d, h = panel.data, panel.data.head

    -- Head block.
    if d.bare then
      emit(put(newline(), " (bare repository)", "NeiltreeGitDetached"))
    elseif h.detached then
      emit(put(newline(), " HEAD detached at " .. (h.oid or "?"), "NeiltreeGitDetached"))
    else
      local l = newline()
      local ahead = (h.ahead or 0) > 0 and (S.up .. h.ahead) or nil
      local behind = (h.behind or 0) > 0 and (S.down .. h.behind) or nil
      local tail = table.concat(vim.tbl_filter(function(x)
        return x ~= nil
      end, { ahead, behind }), " ")
      local tail_cells = tail ~= "" and vim.fn.strdisplaywidth(tail) or 0
      local suffix = h.unborn and " (no commits yet)" or ""
      put(l, " ")
      put(l, truncate(h.branch or "?", width - 1 - #suffix - (tail_cells > 0 and tail_cells + 1 or 0), "tail"), "NeiltreeGitHead")
      put(l, suffix, "NeiltreeGitHint")
      if tail ~= "" then
        pad_to(l, width, tail_cells)
        if ahead then
          put(l, ahead, "NeiltreeGitAhead")
        end
        if ahead and behind then
          put(l, " ")
        end
        if behind then
          put(l, behind, "NeiltreeGitBehind")
        end
      end
      emit(l)

      if not h.unborn then
        local u = put(newline(), " " .. S.arrow .. " ", "NeiltreeGitUpstream")
        if h.upstream then
          put(u, truncate(h.upstream, width - 3 - vim.fn.strdisplaywidth(S.arrow), "tail"), "NeiltreeGitUpstream")
          if h.upstream_gone then
            put(u, " (gone)", "NeiltreeGitBehind")
          end
        else
          put(u, "(no upstream)", "NeiltreeGitHint")
        end
        emit(u)
      end
    end

    local cap = git.max_rows()
    for _, sec in ipairs(sections(panel)) do
      emit(newline())

      local head = newline()
      put(head, " ")
      put(head, panel.collapsed[sec.id] and S.closed or S.open, "NeiltreeGitChevron")
      put(head, " ")
      put(head, sec.label, "NeiltreeGitSection")
      put(head, (" (%d)"):format(#sec.items), "NeiltreeGitCount")
      emit(head, { kind = "section", id = sec.id })

      if not panel.collapsed[sec.id] then
        if #sec.items == 0 then
          hint("    (none)")
        else
          local shown = panel.show_all[sec.id] and #sec.items or math.min(#sec.items, cap)
          for i = 1, shown do
            local it = sec.items[i]
            local l = newline()
            if sec.kind == "file" then
              -- `D` deserves its own color in whichever bucket it lands in.
              local hl = it.code == "D" and "NeiltreeGitDeleted" or sec.hl
              put(l, " ")
              put(l, it.code .. string.rep(" ", math.max(1, 3 - #it.code)), hl)
              put(l, truncate(it.path, width - 4, "head"), hl)
              emit(l, { kind = "file", path = it.path, section = sec.id })
            else
              local marker, hl = " ", "NeiltreeGitBranch"
              if sec.kind == "remote" then
                hl = "NeiltreeGitRemote"
              elseif it.current then
                marker, hl = "*", "NeiltreeGitBranchCurrent"
              elseif it.worktree then
                -- git's own `branch --list` marker for "checked out elsewhere".
                marker = "+"
              end
              local glyph, glyph_hl = track_glyph(it.track)
              local glyph_cells = glyph ~= "" and vim.fn.strdisplaywidth(glyph) or 0
              put(l, " ")
              put(l, marker, hl)
              put(l, "  ")
              put(l, truncate(it.name, width - 4 - (glyph_cells > 0 and glyph_cells + 1 or 0), "tail"), hl)
              if glyph ~= "" then
                pad_to(l, width, glyph_cells)
                put(l, glyph, glyph_hl)
              end
              emit(l, { kind = sec.kind, name = it.name, item = it, section = sec.id })
            end
          end
          if shown < #sec.items then
            emit(
              put(newline(), ("    %s %d more"):format(S.ellipsis, #sec.items - shown), "NeiltreeGitHint"),
              { kind = "more", id = sec.id, section = sec.id }
            )
          end
        end
      end
    end
  end

  vim.bo[panel.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(panel.bufnr, 0, -1, false, lines)
  vim.bo[panel.bufnr].modifiable = false
  vim.bo[panel.bufnr].modified = false

  vim.api.nvim_buf_clear_namespace(panel.bufnr, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, panel.bufnr, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end

  panel.rows = rows
  restore_views(panel, saved)
end

-- ---------------------------------------------------------------- refreshing

local function close_handle(handle)
  pcall(function()
    handle:stop()
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

local function detach_watchers(panel)
  for dir, handle in pairs(panel.watchers or {}) do
    close_handle(handle)
    panel.watchers[dir] = nil
  end
  if panel.timer then
    pcall(function()
      panel.timer:stop()
      if not panel.timer:is_closing() then
        panel.timer:close()
      end
    end)
    panel.timer = nil
  end
end

local function schedule_refresh(panel)
  if not panel.timer then
    panel.timer = uv.new_timer()
    if not panel.timer then
      return
    end
  end
  -- Re-arming restarts it: one refresh after the burst, not one per event.
  panel.timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(panel.bufnr) and #vim.fn.win_findbuf(panel.bufnr) > 0 then
        M.refresh(panel)
      end
    end)
  end)
end

local function attach_watchers(panel)
  if not config.options.auto_refresh or not panel.repo then
    detach_watchers(panel)
    return
  end
  panel.watchers = panel.watchers or {}
  local repo = panel.repo
  -- HEAD and the index live in `git_dir`; `refs/` and `packed-refs` live in
  -- `common_dir`. In a linked worktree those are different directories, so
  -- watching only one leaves half the panel stale.
  --
  -- The working tree needs `root` as well: creating a file changes nothing
  -- under `.git`, so the status half of the panel would never notice it.
  -- All of these are non-recursive - the recursive libuv flag only exists on
  -- macOS/Windows, and one watcher per directory in a working tree is
  -- exactly the cost watch.lua caps itself to avoid. So a change made deep
  -- in the tree by another program is caught by the catch-up autocmds below
  -- (or `R`) rather than instantly.
  local wanted = {}
  local dirs = { repo.git_dir, repo.common_dir, repo.common_dir .. "/refs/heads", repo.common_dir .. "/refs/remotes" }
  if not repo.bare then
    table.insert(dirs, repo.root)
  end
  for _, dir in ipairs(dirs) do
    wanted[dir] = true
  end

  for dir, handle in pairs(panel.watchers) do
    if not wanted[dir] then
      close_handle(handle)
      panel.watchers[dir] = nil
    end
  end
  for dir in pairs(wanted) do
    if not panel.watchers[dir] then
      -- Watching legitimately fails on filesystems with no change
      -- notifications (network mounts, /mnt/... under WSL); the catch-up
      -- autocmds cover those, so there is nothing to report.
      local handle = uv.new_fs_event()
      local ok = handle
        and pcall(function()
          handle:start(dir, {}, function()
            schedule_refresh(panel)
          end)
        end)
      if ok then
        panel.watchers[dir] = handle
      elseif handle then
        close_handle(handle)
      end
    end
  end
end

--- Re-read everything from git and repaint. Safe to call from anywhere:
--- overlapping refreshes (a watcher, a manual `R`, a post-checkout repaint)
--- are resolved by a generation counter, so a slow response can never paint
--- over a newer one.
function M.refresh(panel)
  if not panel or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end
  panel.gen = panel.gen + 1
  local gen = panel.gen

  local function current()
    return panel.gen == gen and vim.api.nvim_buf_is_valid(panel.bufnr)
  end

  local function collect(repo)
    git.collect(repo, function(data, err)
      if not current() then
        return
      end
      if data then
        panel.data, panel.err = data, nil
      else
        -- Forget the repo so the next refresh re-resolves it: this is how a
        -- `rm -rf .git` degrades to "not a git repository" instead of
        -- erroring against a stale path forever.
        panel.repo, panel.err = nil, err
      end
      render(panel)
      attach_watchers(panel)
    end)
  end

  if panel.repo then
    collect(panel.repo)
  else
    git.resolve(panel.root, function(repo, err)
      if not current() then
        return
      end
      if not repo then
        panel.err = err
        render(panel)
        return
      end
      panel.repo = repo
      collect(repo)
    end)
  end
end

-- ------------------------------------------------------------------ actions

local function item_at_cursor(panel)
  return panel.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function goto_section(panel, id)
  for i, item in pairs(panel.rows) do
    if item.kind == "section" and item.id == id then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return true
    end
  end
  return false
end

local function set_collapsed(panel, id, collapsed)
  panel.collapsed[id] = collapsed
  render(panel)
  goto_section(panel, id)
end

local function open_file(panel, path)
  local full = util.joinpath(panel.root, path)
  if path:sub(-1) == "/" then
    -- An untracked *directory* (git collapses those into one entry). Hand it
    -- to the tree in the editing window rather than `:edit`-ing a directory.
    sidebar.leave_to_edit_win()
    require("neiltree.ui").open((full:gsub("/+$", "")))
    return
  end
  sidebar.leave_to_edit_win()
  vim.cmd("edit " .. vim.fn.fnameescape(full))
end

--- Work out what `git switch` invocation a branch row means, or nil to do
--- nothing (the caller has already been told why).
local function switch_spec(panel, item)
  if item.kind == "branch" then
    if item.item.current then
      vim.notify(("[neiltree] already on %s"):format(item.name), vim.log.levels.INFO)
      return nil
    end
    if item.item.worktree then
      vim.notify(
        ("[neiltree] '%s' is checked out in another worktree (%s)"):format(item.name, item.item.worktree),
        vim.log.levels.WARN
      )
      return nil
    end
    return { ref = item.name }, item.name
  end

  local branch = item.item.branch
  local existing
  for _, b in ipairs(panel.data.locals) do
    if b.name == branch then
      existing = b
      break
    end
  end
  if not existing then
    -- `--track <remote>/<branch>` rather than a bare `git switch <branch>`:
    -- the bare form is ambiguous the moment two remotes both have a branch
    -- of that name, the qualified one never is.
    return { ref = item.name, track = true }, ("%s (tracking %s)"):format(branch, item.name)
  end
  if existing.upstream == item.name then
    return { ref = branch }, branch
  end
  local choice = vim.fn.confirm(
    ("neiltree: local '%s' already exists and tracks %s, not %s."):format(
      branch,
      existing.upstream or "nothing",
      item.name
    ),
    ("&Switch to local %s\n&Detach at %s\n&Cancel"):format(branch, item.name),
    3
  )
  if choice == 1 then
    return { ref = branch }, branch
  elseif choice == 2 then
    return { ref = item.name, detach = true }, item.name .. " (detached)"
  end
  return nil
end

local function checkout(panel, item)
  if panel.busy then
    vim.notify("[neiltree] a git operation is already running", vim.log.levels.WARN)
    return
  end
  if panel.data.bare then
    vim.notify("[neiltree] bare repository: there is no working tree to switch", vim.log.levels.WARN)
    return
  end

  local spec, label = switch_spec(panel, item)
  if not spec then
    return
  end

  local dirty = #panel.data.staged + #panel.data.unstaged + #panel.data.conflicts
  if config.options.confirm_changes and dirty > 0 then
    local from = panel.data.head.branch or ("detached at " .. (panel.data.head.oid or "?"))
    local msg = ("neiltree: switch from %s to %s?\n\n  %d file(s) have local changes - git will carry them\n  over, or refuse the switch."):format(
      from,
      label,
      dirty
    )
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      vim.notify("[neiltree] switch cancelled", vim.log.levels.WARN)
      return
    end
  end

  -- Async, like every other subprocess here. The cursor and the focused
  -- window deliberately stay where they are; the busy line shifts every row
  -- down by one, which the key-based cursor restore absorbs.
  panel.busy = "switching to " .. label
  render(panel)

  git.switch(panel.repo, spec, function(ok, stderr)
    if not vim.api.nvim_buf_is_valid(panel.bufnr) then
      return
    end
    panel.busy = nil
    if ok then
      vim.notify(("[neiltree] switched to %s"):format(label), vim.log.levels.INFO)
      -- The working tree just changed under every open buffer and every open
      -- tree. Nothing else does this, and without it you go on editing
      -- content from the branch you left.
      pcall(vim.cmd, "checktime")
      require("neiltree.ui").refresh_all_trees()
    else
      local msg = vim.trim(stderr or "")
      vim.notify("[neiltree] " .. (msg ~= "" and msg or "git switch failed"), vim.log.levels.ERROR)
    end
    M.refresh(panel)
  end)
end

local function show_help()
  local km = config.options.keymaps
  require("neiltree.ui").lines_float({
    "neiltree git panel",
    "",
    km.select .. "  switch branch / open file / fold section",
    km.expand .. "  unfold the section under the cursor",
    km.collapse .. "  fold the section, or jump to its header",
    km.parent_dir .. "  jump to the section header",
    km.refresh .. "  re-read from git",
    km.close .. "  close the sidebar",
    "",
    "read-only: stage/commit/fetch are not bound",
  })
end

local function setup_keymaps(panel)
  local km = config.options.keymaps
  local opts = { buffer = panel.bufnr, silent = true, nowait = true }

  vim.keymap.set("n", km.select, function()
    local item = item_at_cursor(panel)
    if not item then
      return
    end
    if item.kind == "section" then
      set_collapsed(panel, item.id, not panel.collapsed[item.id])
    elseif item.kind == "more" then
      panel.show_all[item.id] = true
      render(panel)
    elseif item.kind == "file" then
      open_file(panel, item.path)
    else
      checkout(panel, item)
    end
  end, opts)

  vim.keymap.set("n", km.expand, function()
    local item = item_at_cursor(panel)
    if item and item.kind == "section" then
      set_collapsed(panel, item.id, false)
    end
  end, opts)

  vim.keymap.set("n", km.collapse, function()
    local item = item_at_cursor(panel)
    if not item then
      return
    end
    if item.kind == "section" then
      set_collapsed(panel, item.id, true)
    elseif item.section then
      goto_section(panel, item.section)
    end
  end, opts)

  vim.keymap.set("n", km.parent_dir, function()
    local item = item_at_cursor(panel)
    if item and item.section then
      goto_section(panel, item.section)
    end
  end, opts)

  vim.keymap.set("n", km.refresh, function()
    M.refresh(panel)
  end, opts)

  vim.keymap.set("n", km.close, function()
    if vim.api.nvim_get_current_win() == sidebar.get() then
      sidebar.close()
    else
      vim.cmd("close")
    end
  end, opts)

  vim.keymap.set("n", km.help, show_help, opts)
end

-- ------------------------------------------------------------ open / toggle

local group
local function ensure_autocmds()
  if group then
    return
  end
  -- A group of its own: `neiltree_auto_refresh` is created with
  -- `clear = true`, so reusing that name would silently delete the file
  -- tree's catch-up autocmds.
  group = vim.api.nvim_create_augroup("neiltree_git", { clear = true })
  -- The catch-up triggers: every moment something outside this panel has
  -- just plausibly touched the repo. `BufWritePost` is the big one during a
  -- normal editing session - saving a file is how the working tree changes
  -- most often, and it happens too deep in the tree for the root watcher.
  -- Routed through the debounce so a `:wa` over twenty buffers, or a burst
  -- of events, still costs one refresh.
  vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave", "ShellCmdPost", "DirChanged", "BufWritePost" }, {
    group = group,
    callback = function()
      for _, panel in pairs(panels) do
        if vim.api.nvim_buf_is_valid(panel.bufnr) and #vim.fn.win_findbuf(panel.bufnr) > 0 then
          schedule_refresh(panel)
        end
      end
    end,
  })
  -- A resize changes every truncation decision, but nothing git knows.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for _, panel in pairs(panels) do
        if panel.data and #vim.fn.win_findbuf(panel.bufnr) > 0 then
          render(panel)
        end
      end
    end,
  })
end

--- Exact-match buffer lookup by name, or -1 - `vim.fn.bufnr(name)` treats
--- its argument as a pattern, so a repo whose path is a prefix of another's
--- would match the wrong buffer. Same reasoning as ui.find_buf_by_name.
local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

local function get_or_create(root)
  local panel = panels[root]
  if panel and vim.api.nvim_buf_is_valid(panel.bufnr) then
    return panel
  end

  local name = "neiltree-git://" .. root
  local bufnr = find_buf(name)
  if bufnr == -1 then
    -- Unlisted scratch, which is already nofile/hide/noswapfile. `hide`
    -- matters: the panel has to survive being swapped out of the sidebar.
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].filetype = "neiltreegit"
  vim.bo[bufnr].modifiable = false
  -- Generated content: no reason for a render to be undoable.
  vim.bo[bufnr].undolevels = -1
  vim.b[bufnr].neiltree_git_root = root

  panel = {
    bufnr = bufnr,
    root = root,
    gen = 0,
    rows = {},
    collapsed = { remotes = config.options.git.remotes_collapsed },
    show_all = {},
    watchers = {},
  }
  panels[root] = panel

  setup_keymaps(panel)
  ensure_autocmds()

  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    callback = function()
      M.refresh(panel)
    end,
  })
  -- A panel swapped out of the sidebar is invisible; keeping its watchers
  -- alive would repaint it for nobody.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      attach_watchers(panel)
      M.refresh(panel)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = bufnr,
    callback = function()
      detach_watchers(panel)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      detach_watchers(panel)
      panels[root] = nil
      sidebar.prune()
    end,
  })

  return panel
end

--- Which directory `--git` with no argument means. Prefers whatever the
--- sidebar is already rooted at, so `--sidebar ~/proj/foo` followed by
--- `--git` shows *that* repo rather than cwd's.
local function default_dir()
  local state = require("neiltree.state")
  local slot = sidebar.buf()
  local st = slot and state.get(slot)
  if st then
    return st.root.path
  end
  st = state.get(vim.api.nvim_get_current_buf())
  if st then
    return st.root.path
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.bo.buftype == "" then
    return vim.fs.dirname(name)
  end
  return vim.uv.cwd()
end

local function close_panel(panel)
  local restore = panel and panel.restore_buf
  if restore and vim.api.nvim_buf_is_valid(restore) and vim.bo[restore].filetype == "neiltree" then
    -- Put back whatever the panel displaced, rather than leaving a hole
    -- where the file tree was.
    panel.restore_buf = nil
    sidebar.place(restore)
    return
  end
  if not sidebar.close() then
    vim.notify("[neiltree] cannot close the sidebar here", vim.log.levels.WARN)
  end
end

--- Toggle the git panel in the sidebar slot for `path` (default: the tree's
--- root, else the current file's directory, else cwd).
function M.toggle(path, opts)
  local ui = require("neiltree.ui")
  ui.set_highlights()
  ui.ensure_global_autocmds()

  local dir = path and util.abspath(path) or default_dir()

  -- Showing a panel whose repo already contains `dir`? Then this press is
  -- the toggle-off half of the gesture. Decided from the paths alone, so
  -- the common case - the same command twice - costs no subprocess.
  local slot = sidebar.buf()
  if slot and vim.bo[slot].filetype == "neiltreegit" then
    local root = vim.b[slot].neiltree_git_root
    if root and (dir == root or dir:sub(1, #root + 1) == root .. "/") then
      close_panel(panels[root])
      return
    end
  end

  git.resolve(dir, function(repo, err)
    if not repo then
      -- Deliberately does not replace an already-open file tree with an
      -- error panel: `--git` outside a repo tells you why and changes
      -- nothing.
      vim.notify(("[neiltree] %s: %s"):format(dir, err), vim.log.levels.WARN)
      return
    end
    local panel = get_or_create(repo.root)
    panel.repo = repo
    if opts and opts.expand_remotes then
      panel.collapsed.remotes = false
    end

    local prev = sidebar.buf()
    if prev and prev ~= panel.bufnr and vim.bo[prev].filetype == "neiltree" then
      panel.restore_buf = prev
    end
    if sidebar.place(panel.bufnr) then
      M.refresh(panel)
    end
  end)
end

return M
