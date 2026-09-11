local config = require("neiltree.config")
local git = require("neiltree.git")
local graph = require("neiltree.graph")
local line = require("neiltree.line")
local checkout = require("neiltree.checkout")

--- The commit graph: a centered float showing the DAG one row per commit,
--- with branch and tag names as inline badges. A float rather than the
--- sidebar because a graph is mostly horizontal - lanes, refs, subject,
--- author, date and hash do not fit in 30 columns, and cutting any of them
--- is what makes a narrow graph useless.
local M = {}

local ns = vim.api.nvim_create_namespace("neiltree_graph")

--- repo root -> view. Exposed for poking at from `:lua`; there is no test
--- harness in this repo.
local views = {}
M._views = views

-- Cycled by lane index, which is what makes parallel branches tellable apart
-- at a glance. Colouring by lane rather than by branch means a lane that is
-- freed and reused keeps its colour - the same trade-off every terminal graph
-- makes, and far cheaper than tracking an identity per edge.
local LANE_HL = {
  "NeiltreeGitLane1",
  "NeiltreeGitLane2",
  "NeiltreeGitLane3",
  "NeiltreeGitLane4",
  "NeiltreeGitLane5",
  "NeiltreeGitLane6",
}

local function lane_hl(i)
  return LANE_HL[((i - 1) % #LANE_HL) + 1]
end

local SHA_W, DATE_W, AUTHOR_W = 8, 5, 14

-- Git's relative dates are the most readable form for browsing history and
-- the least predictable width - "16 minutes ago" through "3 years, 5 months
-- ago". Compacting to a number and a unit fixes the column at 4 cells and
-- buys all of that width back for the subject.
local UNIT = { second = "s", minute = "m", hour = "h", day = "d", week = "w", month = "mo", year = "y" }

local function short_age(rel)
  local n, unit = rel:match("^(%d+) (%a+)")
  if not n then
    return rel:find("now", 1, true) and "now" or ""
  end
  return n .. (UNIT[(unit:gsub("s$", ""))] or unit:sub(1, 1))
end

-- Past this many parallel branches the lanes would eat the subject column;
-- the graph is still correct, we just stop widening for it.
local MAX_LANES = 16

-- Badge order, most actionable first. It matters because the badge budget
-- drops whatever does not fit: git's own `%D` order will happily put
-- `origin/foo` ahead of the local `foo`, and the local branch is the one you
-- would actually switch to.
local REF_RANK = { tag = 2, remote = 3, head = 4 }

local function ref_rank(ref)
  if ref.kind == "local" then
    return ref.head and 0 or 1
  end
  return REF_RANK[ref.kind] or 3
end

--- `commit.refs` in display order. Lua's `table.sort` is not stable, so the
--- original position is the tiebreaker - refs of equal rank must not shuffle
--- between renders.
local function ordered_refs(commit)
  local out = {}
  for i, ref in ipairs(commit.refs) do
    table.insert(out, { ref = ref, i = i })
  end
  table.sort(out, function(a, b)
    local ra, rb = ref_rank(a.ref), ref_rank(b.ref)
    if ra ~= rb then
      return ra < rb
    end
    return a.i < b.i
  end)
  local refs = {}
  for i, entry in ipairs(out) do
    refs[i] = entry.ref
  end
  return refs
end

local function ref_hl(ref)
  if ref.kind == "tag" then
    return "NeiltreeGitTag"
  elseif ref.kind == "remote" then
    return "NeiltreeGitRemote"
  elseif ref.head then
    return "NeiltreeGitRefHead"
  elseif ref.kind == "head" then
    return "NeiltreeGitDetached"
  end
  return "NeiltreeGitRefLocal"
end

-- ---------------------------------------------------------------- rendering

local function view_width(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    return vim.api.nvim_win_get_width(view.win)
  end
  return math.min(math.floor(vim.o.columns * 0.9), 140)
end

local function render(view)
  if not vim.api.nvim_buf_is_valid(view.bufnr) then
    return
  end
  local S = line.sym()
  local width = view_width(view)
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

  if view.err then
    emit(line.put(line.new(), " " .. line.truncate(view.err, width - 1, "tail"), "NeiltreeGitError"))
    emit(line.put(line.new(), " press " .. config.options.keymaps.refresh .. " to retry", "NeiltreeGitHint"))
  elseif not view.rows then
    emit(line.put(line.new(), " " .. S.ellipsis .. " loading", "NeiltreeGitHint"))
  elseif #view.rows == 0 then
    emit(line.put(line.new(), " (no commits yet)", "NeiltreeGitHint"))
  else
    local lane_w = 0
    for _, row in ipairs(view.rows) do
      lane_w = math.max(lane_w, math.min(row.ncols, MAX_LANES))
    end

    -- Drop the trailing columns rather than the subject when the window is
    -- narrow: which commit it is matters more than who wrote it.
    local right_w = SHA_W
    local show_date = width - lane_w > 40
    local show_author = width - lane_w > 60
    if show_date then
      right_w = right_w + 2 + DATE_W
    end
    if show_author then
      right_w = right_w + 2 + AUTHOR_W
    end
    local mid_w = width - lane_w - 2 - right_w - 1

    for _, row in ipairs(view.rows) do
      local commit = row.commit
      local l = line.new()
      line.put(l, " ")
      for col = 1, lane_w do
        line.put(l, graph.glyph(row, col, { ascii = line.ascii() }), lane_hl(col))
      end
      line.put(l, " ")

      -- Refs first, as badges, then whatever room is left goes to the
      -- subject - the same reading order as VS Code's graph. A commit that
      -- every branch happens to point at (a fresh repo, a just-merged
      -- release) would otherwise push the subject off the row entirely, so
      -- badges get at most half the middle and the rest are counted off.
      local used, dropped = 0, 0
      local badge_budget = math.max(math.floor(mid_w / 2), 12)
      for _, ref in ipairs(ordered_refs(commit)) do
        local name = ref.kind == "tag" and "tag:" .. ref.name or ref.name
        local chip = line.truncate(name, badge_budget, "tail")
        local w = vim.fn.strdisplaywidth(chip)
        if dropped == 0 and used + w + 1 <= badge_budget then
          line.put(l, chip, ref_hl(ref))
          line.put(l, " ")
          used = used + w + 1
        else
          dropped = dropped + 1
        end
      end
      if dropped > 0 then
        local more = ("+%d "):format(dropped)
        line.put(l, more, "NeiltreeGitHint")
        used = used + #more
      end
      -- Two spaces after the badges, not one: colour separates them from the
      -- subject, but the gap is what keeps it readable without it.
      if used > 0 then
        line.put(l, " ")
        used = used + 1
      end
      line.put(l, line.truncate(commit.subject, mid_w - used, "tail"), "NeiltreeGitSubject")

      if show_author then
        line.pad_col(l, width - right_w - 1)
        line.put(l, line.truncate(commit.author, AUTHOR_W, "tail"), "NeiltreeGitAuthor")
      end
      if show_date then
        -- Right-aligned, so the ragged 2-to-4-character ages line up on the
        -- edge nearest the hash instead of drifting.
        local age = short_age(commit.when)
        line.pad_col(l, width - SHA_W - 2 - vim.fn.strdisplaywidth(age))
        line.put(l, age, "NeiltreeGitDate")
      end
      line.pad_col(l, width - SHA_W - 1)
      line.put(l, commit.hash:sub(1, SHA_W), "NeiltreeGitSha")

      emit(l, { kind = "commit", commit = commit, hash = commit.hash })
    end

    if view.truncated then
      emit(
        line.put(line.new(), ("  %s load more (showing %d)"):format(S.ellipsis, #view.rows), "NeiltreeGitHint"),
        { kind = "more" }
      )
    end
  end

  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false
  vim.bo[view.bufnr].modified = false

  vim.api.nvim_buf_clear_namespace(view.bufnr, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, view.bufnr, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  view.lines = rows

  if view.win and vim.api.nvim_win_is_valid(view.win) then
    local desc = view.data and view.data.head or {}
    local head = desc.detached and ("detached at " .. (desc.oid or "?")) or (desc.branch or "?")
    pcall(vim.api.nvim_win_set_config, view.win, {
      title = (" %s · %s "):format(vim.fs.basename(view.root), head),
      title_pos = "center",
    })
  end
end

-- ---------------------------------------------------------------- refreshing

--- Re-read the DAG. `git.log` needs the set of real remote names to tell
--- `origin/x` from a local branch literally called `origin/x` - `%D` prints
--- them identically - so the two calls are sequential rather than
--- concurrent. Both are local and quick; correctness is worth the round trip.
function M.refresh(view)
  if not vim.api.nvim_buf_is_valid(view.bufnr) then
    return
  end
  view.gen = view.gen + 1
  local gen = view.gen
  local function current()
    return view.gen == gen and vim.api.nvim_buf_is_valid(view.bufnr)
  end

  git.collect(view.repo, function(data, err)
    if not current() then
      return
    end
    if not data then
      view.repo, view.err = nil, err
      render(view)
      return
    end
    view.data = data

    local remotes = {}
    for _, r in ipairs(data.remotes) do
      remotes[r.remote] = true
    end

    git.log(view.repo, { limit = view.limit, remotes = remotes }, function(commits, log_err)
      if not current() then
        return
      end
      if not commits then
        view.err = log_err
        render(view)
        return
      end
      view.err = nil
      view.truncated = #commits >= view.limit
      view.rows = graph.build(commits)
      render(view)
    end)
  end)
end

-- ------------------------------------------------------------------ actions

local function item_at_cursor(view)
  if not view.lines then
    return nil
  end
  return view.lines[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Switch to the branch sitting on this commit. Tags are skipped (checking
--- one out means a detached HEAD, which is not what was asked for) and a
--- commit carrying several branches asks which.
local function switch_here(view, commit)
  local local_here = {}
  for _, ref in ipairs(ordered_refs(commit)) do
    if ref.kind == "local" then
      local_here[ref.name] = true
    end
  end
  local branches = {}
  for _, ref in ipairs(ordered_refs(commit)) do
    -- `main` and `origin/main` sitting on the same commit are one
    -- destination, not two: offering both is a choice with no meaning, and
    -- it is the commonest shape there is.
    if ref.kind == "local" or (ref.kind == "remote" and not local_here[ref.branch]) then
      table.insert(branches, ref)
    end
  end
  if #branches == 0 then
    vim.notify("[neiltree] no branch on this commit to switch to", vim.log.levels.WARN)
    return
  end

  local ref = branches[1]
  if #branches > 1 then
    -- `vim.fn.confirm` accelerators are single characters, so nine is the
    -- practical ceiling. Past that the sidebar panel's branch list is the
    -- right tool, and the prompt says so rather than silently hiding the rest.
    local shown = math.min(#branches, 9)
    local choices = {}
    for i = 1, shown do
      table.insert(choices, ("&%d %s"):format(i, branches[i].name))
    end
    local prompt = "neiltree: this commit has several branches - switch to which?"
    if #branches > shown then
      prompt = prompt
        .. ("\n\n  (%d more not listed - use the branch list in %s)"):format(#branches - shown, ":Neiltree --git")
    end
    local pick = vim.fn.confirm(prompt, table.concat(choices, "\n") .. "\n&Cancel", shown + 1)
    if pick < 1 or pick > shown then
      return
    end
    ref = branches[pick]
  end

  local head = view.data and view.data.head or {}
  if ref.kind == "local" and head.branch == ref.name then
    vim.notify(("[neiltree] already on %s"):format(ref.name), vim.log.levels.INFO)
    return
  end
  for _, b in ipairs(view.data.locals) do
    if b.name == ref.name and b.worktree then
      vim.notify(
        ("[neiltree] '%s' is checked out in another worktree (%s)"):format(ref.name, b.worktree),
        vim.log.levels.WARN
      )
      return
    end
  end

  local spec, label
  if ref.kind == "remote" then
    spec, label = checkout.spec_for(ref.branch, ref.name, view.data.locals)
  else
    spec, label = checkout.spec_for(ref.name, nil, view.data.locals)
  end
  if not spec then
    return
  end

  local d = view.data
  local dirty = #d.staged + #d.unstaged + #d.conflicts
  checkout.switch(view.repo, spec, label, dirty, function()
    M.refresh(view)
  end)
end

local function close(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  view.win = nil
end

local function show_help()
  local km = config.options.keymaps
  require("neiltree.ui").lines_float({
    "neiltree commit graph",
    "",
    km.select .. "  switch to the branch on this commit",
    km.refresh .. "  re-read from git",
    km.close .. " / <Esc>  close",
    "",
    "one row per commit; badges are branches and tags",
  })
end

local function setup_keymaps(view)
  local km = config.options.keymaps
  local opts = { buffer = view.bufnr, silent = true, nowait = true }

  vim.keymap.set("n", km.select, function()
    local item = item_at_cursor(view)
    if not item then
      return
    end
    if item.kind == "more" then
      view.limit = view.limit * 2
      M.refresh(view)
    else
      switch_here(view, item.commit)
    end
  end, opts)

  vim.keymap.set("n", km.refresh, function()
    M.refresh(view)
  end, opts)

  vim.keymap.set("n", km.help, show_help, opts)

  for _, lhs in ipairs({ km.close, "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", lhs, function()
      close(view)
    end, opts)
  end
end

-- ------------------------------------------------------------------ opening

local function open_float(bufnr)
  local width = math.min(math.floor(vim.o.columns * 0.9), 140)
  local height = math.min(math.floor(vim.o.lines * 0.9), 40)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  return win
end

local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

local function get_or_create(root)
  local view = views[root]
  if view and vim.api.nvim_buf_is_valid(view.bufnr) then
    return view
  end

  local name = "neiltree-graph://" .. root
  local bufnr = find_buf(name)
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].filetype = "neiltreegraph"
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].undolevels = -1

  view = { bufnr = bufnr, root = root, gen = 0, limit = config.options.git.graph_limit }
  views[root] = view
  setup_keymaps(view)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      views[root] = nil
    end,
  })
  return view
end

--- Open the commit graph for `path` (default: the sidebar's root, else the
--- current file's directory, else cwd). Already open on this tabpage? Focus
--- it rather than stacking a second float.
function M.open(path, opts)
  local ui = require("neiltree.ui")
  ui.set_highlights()
  ui.ensure_global_autocmds()

  local util = require("neiltree.util")
  local dir = path and util.abspath(path) or require("neiltree.gitpanel").default_dir()

  git.resolve(dir, function(repo, err)
    if not repo then
      vim.notify(("[neiltree] %s: %s"):format(dir, err), vim.log.levels.WARN)
      return
    end
    local view = get_or_create(repo.root)
    view.repo = repo
    if view.win and vim.api.nvim_win_is_valid(view.win) then
      vim.api.nvim_set_current_win(view.win)
      return
    end
    view.win = open_float(view.bufnr)
    render(view)
    M.refresh(view)
  end)
end

return M
