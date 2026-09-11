--- Lane assignment for a commit DAG: turns a flat, newest-first commit list
--- into one drawable row per commit.
---
--- Deliberately not `git log --graph`, which git renders itself: git spends
--- *extra rows* on edge transitions (the `|\` / `|/` lines), so a row there
--- is not a commit and a cursor cannot be mapped back to one. Here every row
--- is exactly one commit and edges turn within that same row, which is both
--- what VS Code's graph looks like and what makes the view selectable.
local M = {}

-- Which sides of a cell an edge touches. Combined into a key rather than
-- bit-ored so this needs no bit library.
local N, S, E, W = 1, 2, 4, 8

local GLYPH = {
  [0] = " ",
  [N] = "╵",
  [S] = "╷",
  [E] = "╶",
  [W] = "╴",
  [N + S] = "│",
  [E + W] = "─",
  [N + W] = "╯",
  [N + E] = "╰",
  [S + W] = "╮",
  [S + E] = "╭",
  [N + S + W] = "┤",
  [N + S + E] = "├",
  [N + E + W] = "┴",
  [S + E + W] = "┬",
  [N + S + E + W] = "┼",
}

--- ASCII stand-ins, for `icons = false` / a terminal with no box-drawing.
local ASCII = {
  [0] = " ",
  [N] = "'",
  [S] = ".",
  [E] = "-",
  [W] = "-",
  [N + S] = "|",
  [E + W] = "-",
  [N + W] = "'",
  [N + E] = "'",
  [S + W] = ".",
  [S + E] = ".",
  [N + S + W] = "+",
  [N + S + E] = "+",
  [N + E + W] = "+",
  [S + E + W] = "+",
  [N + S + E + W] = "+",
}

--- Leftmost free lane, growing the array if every lane is taken. Free slots
--- hold `false` rather than nil so the array stays dense and `#lanes` keeps
--- meaning what it looks like it means.
local function first_free(lanes)
  for i = 1, #lanes do
    if not lanes[i] then
      return i
    end
  end
  lanes[#lanes + 1] = false
  return #lanes
end

--- @param commits table[] newest-first, each `{ hash = , parents = { ... } }`
--- @return table[] one row per commit: `{ commit, lane, cells, ncols }`,
--- where `cells[i]` is `{ key = <side mask>, lane = i }` for column `i`.
function M.build(commits)
  -- lane index -> hash that lane is currently descending toward, or false
  local lanes = {}
  local rows = {}

  for _, commit in ipairs(commits) do
    -- Lanes already routed to this commit by one of its children. The
    -- leftmost becomes the commit's own lane; the rest are branches merging
    -- back in from the right, and end here.
    local incoming = {}
    for i = 1, #lanes do
      if lanes[i] == commit.hash then
        table.insert(incoming, i)
      end
    end

    -- Snapshot before we reassign: these are the lanes with an edge arriving
    -- from the row above, which is what gives a cell its `N` side.
    local had_above = {}
    for i = 1, #lanes do
      had_above[i] = lanes[i] and true or false
    end

    local lane
    if #incoming > 0 then
      lane = incoming[1]
      for _, i in ipairs(incoming) do
        lanes[i] = false
      end
    else
      -- No child in view routed to it: a branch tip, so it starts a lane.
      lane = first_free(lanes)
    end
    lanes[lane] = false

    -- The first parent continues this commit's own lane straight down, which
    -- is what keeps a branch's history in one column. Every further parent
    -- is a merge: reuse the lane it already occupies if some other child is
    -- already heading for it, otherwise open one.
    local outgoing = {}
    if commit.parents[1] then
      lanes[lane] = commit.parents[1]
    end
    for k = 2, #commit.parents do
      local parent = commit.parents[k]
      local target
      for i = 1, #lanes do
        if lanes[i] == parent then
          target = i
          break
        end
      end
      if not target then
        target = first_free(lanes)
        lanes[target] = parent
      end
      table.insert(outgoing, target)
    end

    local mask = {}
    local function add(col, sides)
      mask[col] = (mask[col] or 0)
      -- Idempotent per side, so overlapping edges can't corrupt the key.
      for _, side in ipairs({ N, S, E, W }) do
        if sides % (side * 2) >= side and mask[col] % (side * 2) < side then
          mask[col] = mask[col] + side
        end
      end
    end

    --- Draw the horizontal leg of an edge that changes column on this row.
    --- The vertical sides at either end come from the `had_above` / active
    --- passes below, so this only lays down the turn and the run.
    local function connect(from, to)
      if from == to then
        return
      end
      local step = to > from and 1 or -1
      add(from, to > from and E or W)
      for col = from + step, to - step, step do
        add(col, E + W)
      end
      add(to, to > from and W or E)
    end

    for i = 1, #lanes do
      if had_above[i] then
        add(i, N)
      end
      if lanes[i] then
        add(i, S)
      end
    end
    for _, i in ipairs(incoming) do
      connect(lane, i)
    end
    for _, i in ipairs(outgoing) do
      connect(lane, i)
    end

    -- Trailing lanes that went free leave nothing to draw.
    while #lanes > 0 and not lanes[#lanes] do
      local last = #lanes
      if (mask[last] or 0) ~= 0 then
        break
      end
      lanes[last] = nil
    end

    local ncols = lane
    for col in pairs(mask) do
      ncols = math.max(ncols, col)
    end

    local cells = {}
    for col = 1, ncols do
      cells[col] = mask[col] or 0
    end

    table.insert(rows, { commit = commit, lane = lane, cells = cells, ncols = ncols })
  end

  return rows
end

--- The glyph for one cell. `col == row.lane` is the commit itself, which
--- always wins over whatever edges pass through it.
function M.glyph(row, col, opts)
  local set = (opts and opts.ascii) and ASCII or GLYPH
  if col == row.lane then
    return (opts and opts.ascii) and "*" or "●"
  end
  return set[row.cells[col] or 0] or " "
end

--- Render a row's lane columns as a plain string. Used by the tests, and by
--- anything that wants the graph without the highlight plumbing.
function M.line(row, opts)
  local out = {}
  for col = 1, row.ncols do
    out[col] = M.glyph(row, col, opts)
  end
  return table.concat(out)
end

return M
