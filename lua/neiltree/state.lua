local tree = require("neiltree.tree")

local M = {}

--- bufnr -> state
M.buffers = {}

function M.get(bufnr)
  return M.buffers[bufnr]
end

function M.new(bufnr, root_path)
  local st = {
    bufnr = bufnr,
    root = tree.new_root(root_path),
    ns = vim.api.nvim_create_namespace("neiltree_buf_" .. bufnr),
    -- mark_id -> node, for every currently-rendered line
    mark_to_node = {},
  }
  M.buffers[bufnr] = st
  return st
end

function M.clear(bufnr)
  M.buffers[bufnr] = nil
end

--- Collect every node currently reachable in the in-memory tree (whether or
--- not it is presently visible), keyed by id. Used to resolve snapshot ids
--- referenced by extmarks even if their line is currently scrolled off /
--- their parent got collapsed after the mark was created (rare, since we
--- always drop descendant marks on collapse, but kept for robustness).
function M.all_nodes(st)
  local by_id = {}
  local function walk(node)
    if not node.children then
      return
    end
    for _, child in ipairs(node.children) do
      by_id[child.id] = child
      if child.expanded then
        walk(child)
      end
    end
  end
  walk(st.root)
  return by_id
end

return M
