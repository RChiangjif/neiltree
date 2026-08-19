local fs = require("neiltree.fs")
local util = require("neiltree.util")
local config = require("neiltree.config")

local M = {}

--- Create the (invisible) root node for a tree rooted at `path`.
function M.new_root(path)
  return {
    id = "root",
    path = util.abspath(path),
    type = "directory",
    depth = -1,
    expanded = true,
    loaded = false,
    children = nil,
  }
end

--- (Re)scan `node`'s directory from disk and populate `node.children`.
--- Reuses ids for entries that already existed (by name), so identity
--- (and therefore extmark associations set up elsewhere) survives a
--- refresh whenever possible.
function M.load_children(node)
  local previous_by_name = {}
  if node.children then
    for _, child in ipairs(node.children) do
      previous_by_name[child.name] = child
    end
  end

  local entries, err = fs.scandir(node.path, { show_hidden = config.options.show_hidden })
  if err then
    vim.notify("[neiltree] " .. err, vim.log.levels.ERROR)
    node.children = {}
    node.loaded = true
    return
  end

  local children = {}
  for _, entry in ipairs(entries) do
    local prev = previous_by_name[entry.name]
    local child
    if prev and prev.type == entry.type then
      child = prev
    else
      child = {
        id = util.next_id(),
        name = entry.name,
        type = entry.type,
        expanded = false,
        loaded = false,
        children = nil,
      }
    end
    child.name = entry.name
    child.path = util.joinpath(node.path, entry.name)
    child.depth = node.depth + 1
    child.parent = node
    table.insert(children, child)
  end
  node.children = children
  node.loaded = true
end

--- Recursively load and expand every directory under `node` (which must
--- already be loaded). Symlinks are never followed (`fs.scandir` reports
--- their dirent type as "link", not "directory", so they simply don't
--- match the walk below) - that's what keeps this safe from symlink
--- cycles.
function M.expand_all(node)
  for _, child in ipairs(node.children) do
    if child.type == "directory" then
      child.expanded = true
      M.load_children(child)
      M.expand_all(child)
    end
  end
end

return M
