local state = require("neiltree.state")
local util = require("neiltree.util")

local M = {}

--- Does `node` (a delete candidate) have any descendant whose line is still
--- present in the buffer? If so, deleting `node` would silently orphan (and
--- silently reparent, via plain indentation arithmetic) that descendant, so
--- the caller must refuse and ask the user to resolve it explicitly instead
--- of guessing.
local function has_visible_descendant(node, alive)
  if not node.children then
    return false
  end
  for _, child in ipairs(node.children) do
    if child.mark_id and alive[child.mark_id] then
      return true
    end
    if has_visible_descendant(child, alive) then
      return true
    end
  end
  return false
end

--- Parse the current buffer state against `st`'s in-memory tree and compute
--- the set of filesystem operations required to make disk match the
--- buffer. Returns `ops, nil` on success, or `nil, errors` (a list of
--- human-readable strings) if the buffer is not in a state that can be
--- safely resolved.
function M.compute(st)
  local bufnr = st.bufnr
  local errors = {}

  -- Live snapshot of every extmark that currently exists in the buffer.
  local alive = {} -- mark_id -> row
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, st.ns, 0, -1, {})) do
    alive[m[1]] = m[2]
  end

  -- Every node that *should* be visible right now (i.e. its parent chain is
  -- expanded). If one of these has no live mark, its line was deleted.
  local expected = state.all_nodes(st)

  local row_to_node = {}
  local deletes = {}
  for _, node in pairs(expected) do
    if node.mark_id and alive[node.mark_id] then
      row_to_node[alive[node.mark_id]] = node
    else
      if node.type == "directory" and has_visible_descendant(node, alive) then
        table.insert(
          errors,
          ("'%s' still has items visible in the buffer below it - delete or move them out first, or delete the whole block"):format(
            node.path
          )
        )
      else
        table.insert(deletes, node)
      end
    end
  end

  if #errors > 0 then
    return nil, errors
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- stack entries: { depth, id, new_abspath, is_dir }
  local stack = { { depth = -1, id = "root", new_abspath = st.root.path, is_dir = true } }
  local moves = {}
  local creates = {}

  for row, line in ipairs(lines) do
    if line:match("%S") then
      local leading = line:match("^\t*") or ""
      local rest = line:sub(#leading + 1)
      if rest:find("^[ \t]") then
        table.insert(errors, ("line %d: use tabs (not spaces) for indentation, with no extra whitespace before the name"):format(row))
      else
        local depth = #leading
        local is_dir_hint = rest:sub(-1) == "/"
        local name = is_dir_hint and rest:sub(1, -2) or rest

        while #stack > 0 and stack[#stack].depth >= depth do
          table.remove(stack)
        end
        local parent = stack[#stack]

        if not parent or depth ~= parent.depth + 1 then
          table.insert(errors, ("line %d: inconsistent indentation (expected depth %d)"):format(row, parent and parent.depth + 1 or 0))
        elseif not parent.is_dir then
          table.insert(errors, ("line %d: parent is not a directory"):format(row))
        else
          local node = row_to_node[row - 1]
          local is_dir = node and (node.type == "directory") or is_dir_hint
          local new_abspath = util.joinpath(parent.new_abspath, name)

          if node then
            local old_parent_id = node.parent and node.parent.id or "root"
            local old_name = node.name
            if old_parent_id ~= parent.id or old_name ~= name then
              if name:find("/") then
                table.insert(errors, ("line %d: renamed name may not contain '/'"):format(row))
              else
                table.insert(moves, {
                  node = node,
                  old_path = node.path,
                  new_path = new_abspath,
                  is_dir = is_dir,
                })
              end
            end
          else
            table.insert(creates, { path = new_abspath, is_dir = is_dir })
          end

          table.insert(stack, { depth = depth, id = node and node.id or ("new:" .. row), new_abspath = new_abspath, is_dir = is_dir })
        end
      end
    end
  end

  if #errors > 0 then
    return nil, errors
  end

  -- A whole deleted subtree shows up as one delete per node it contained
  -- (each lost its own extmark independently). Collapse that down to just
  -- the topmost ancestor of each deleted subtree, both for a readable
  -- confirmation prompt and to avoid redundant rmrf calls.
  table.sort(deletes, function(a, b)
    return #a.path < #b.path
  end)
  local roots = {}
  for _, node in ipairs(deletes) do
    local is_covered = false
    for _, root in ipairs(roots) do
      if node.path:sub(1, #root.path + 1) == root.path .. "/" then
        is_covered = true
        break
      end
    end
    if not is_covered then
      table.insert(roots, node)
    end
  end

  return {
    deletes = roots,
    moves = moves,
    creates = creates,
  }, nil
end

return M
