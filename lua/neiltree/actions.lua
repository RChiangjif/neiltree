local tree = require("neiltree.tree")
local render = require("neiltree.render")
local fs = require("neiltree.fs")
local config = require("neiltree.config")

local M = {}

--- Resolve the node (if any) rendered on buffer line `row` (0-indexed).
function M.node_at_row(st, row)
  local marks = vim.api.nvim_buf_get_extmarks(st.bufnr, st.ns, { row, 0 }, { row, -1 }, {})
  for _, m in ipairs(marks) do
    local node = st.mark_to_node[m[1]]
    if node then
      return node, m[2]
    end
  end
  return nil
end

--- Resolve the node (if any) whose line the cursor is currently on.
function M.node_at_cursor(st)
  return M.node_at_row(st, vim.api.nvim_win_get_cursor(0)[1] - 1)
end

--- Every node whose line falls within buffer rows [row0, row1] (0-indexed,
--- inclusive), in document order. Used for visual-mode cut.
function M.nodes_in_range(st, row0, row1)
  local marks = vim.api.nvim_buf_get_extmarks(st.bufnr, st.ns, { row0, 0 }, { row1, -1 }, {})
  local nodes = {}
  for _, m in ipairs(marks) do
    local node = st.mark_to_node[m[1]]
    if node then
      table.insert(nodes, node)
    end
  end
  return nodes
end

function M.expand(st, node)
  if node.type ~= "directory" or node.expanded then
    return
  end
  if not node.loaded then
    tree.load_children(node)
  end
  node.expanded = true
  render.update_decoration(st, node)
  if #node.children > 0 then
    render.insert_children(st, node)
  end
  require("neiltree.watch").sync(st)
end

function M.collapse(st, node)
  if node.type ~= "directory" or not node.expanded then
    return
  end
  render.remove_descendants(st, node)
  node.expanded = false
  render.update_decoration(st, node)
  require("neiltree.watch").sync(st)
end

function M.toggle(st, node)
  if node.expanded then
    M.collapse(st, node)
  else
    M.expand(st, node)
  end
end

--- <CR>: open a file in the window neiltree was invoked from, or toggle a
--- directory.
function M.select(st, node)
  if node.type == "directory" then
    M.toggle(st, node)
    return
  end
  if require("neiltree.opener").is_external(node.path) then
    require("neiltree.opener").open(node.path)
    return
  end
  if st.float then
    -- Close the floating tree first and land back in the window it was
    -- opened over, so the file opens there instead of replacing the float.
    pcall(vim.api.nvim_win_close, 0, false)
    if st.parent_win and vim.api.nvim_win_is_valid(st.parent_win) then
      vim.api.nvim_set_current_win(st.parent_win)
    end
  elseif st.sidebar then
    -- The sidebar stays open (nvim-tree/nerdtree-style) - move to whatever
    -- window was active before the sidebar, or split one off if the
    -- sidebar is the only window there is.
    local sidebar_win = vim.api.nvim_get_current_win()
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_win() == sidebar_win then
      vim.cmd("vsplit")
    end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(node.path))
end

--- Move the cursor to the line of `node`'s parent directory (or, if `node`
--- is already a top-level entry, do nothing).
--- Returns true if it actually moved the cursor. When `node` has no
--- visible parent line (it's a top-level entry), the caller falls back to
--- `ui.go_up` - re-rooting the tree one directory up - rather than doing
--- nothing, matching oil.nvim's `-` at the top of a listing.
function M.goto_parent(st, node)
  local parent = node.parent
  if not parent or not parent.mark_id then
    return false
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(st.bufnr, st.ns, parent.mark_id, {})
  vim.api.nvim_win_set_cursor(0, { pos[1] + 1, 0 })
  return true
end

--- Move (rename-across-directories) is inherently unrepresentable as a
--- plain text edit once the entry has to jump to a non-adjacent part of
--- the tree: cutting a line's text (by any means - dd, visual delete, ...)
--- is exactly what tells Neovim the underlying entry was deleted, so a
--- cut+paste in the buffer can never be told apart from delete+create.
--- Cut/paste is therefore its own explicit, immediate action instead of
--- something resolved by :w - `st.cut` holds the nodes queued for a move.
function M.cut(st, nodes)
  st.cut = nodes
  vim.notify(("[neiltree] cut %d item(s) - move cursor to a target directory and paste"):format(#nodes))
end

--- Move every node in `st.cut` into the directory under the cursor (or, if
--- the cursor is on a file, alongside that file; if on nothing, into the
--- tree root). Applied to disk immediately, then the tree is resynced from
--- disk so the buffer reflects the result.
function M.paste(st)
  local cut = st.cut
  if not cut or #cut == 0 then
    vim.notify("[neiltree] nothing cut", vim.log.levels.WARN)
    return
  end

  local target_node = M.node_at_cursor(st)
  local dest_dir
  if not target_node then
    dest_dir = st.root.path
  elseif target_node.type == "directory" then
    dest_dir = target_node.path
  else
    dest_dir = target_node.parent and target_node.parent.path or st.root.path
  end

  local util = require("neiltree.util")
  local moves = {}
  for _, node in ipairs(cut) do
    local new_path = util.joinpath(dest_dir, node.name)
    if node.type == "directory" and (dest_dir == node.path or dest_dir:sub(1, #node.path + 1) == node.path .. "/") then
      vim.notify(("[neiltree] cannot move '%s' into itself"):format(node.path), vim.log.levels.ERROR)
    elseif new_path ~= node.path then
      table.insert(moves, { node = node, new_path = new_path })
    end
  end
  if #moves == 0 then
    return
  end

  if config.options.confirm_changes then
    local lines = {}
    for _, mv in ipairs(moves) do
      table.insert(lines, ("MOVE  %s -> %s"):format(mv.node.path, mv.new_path))
    end
    local msg = "neiltree: apply these moves?\n\n  " .. table.concat(lines, "\n  ")
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      vim.notify("[neiltree] paste cancelled", vim.log.levels.WARN)
      return
    end
  end

  -- Moves land on disk immediately (see comment above `M.cut`), so make
  -- sure the buffer has nothing else pending before doing that - resync
  -- would otherwise silently wipe out unrelated unsaved edits along with
  -- refreshing in the moved files.
  local ui = require("neiltree.ui")
  if vim.bo[st.bufnr].modified then
    if vim.fn.confirm(
      "neiltree: paste discards other unsaved edits in the buffer (it resyncs from disk) - continue?",
      "&Yes\n&No",
      2
    ) ~= 1 then
      vim.notify("[neiltree] paste cancelled", vim.log.levels.WARN)
      return
    end
  end

  local errors = {}
  for _, mv in ipairs(moves) do
    local ok, err = fs.move(mv.node.path, mv.new_path)
    if not ok then
      table.insert(errors, ("%s -> %s: %s"):format(mv.node.path, mv.new_path, err))
    end
  end

  st.cut = nil
  ui.resync(st)

  if #errors > 0 then
    vim.notify("[neiltree] some moves failed:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
  else
    vim.notify(("[neiltree] moved %d item(s)"):format(#moves), vim.log.levels.INFO)
  end
end

return M
