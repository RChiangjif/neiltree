local M = {}

--- Join a directory path and a bare name into an absolute path.
function M.joinpath(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

--- Normalize a path to an absolute path with no trailing slash (except "/").
function M.abspath(path)
  path = vim.fs.abspath(path)
  path = vim.fs.normalize(path)
  if #path > 1 and path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

local id_counter = 0
--- Generate a fresh unique id for a tree node. Ids are only unique within a
--- single Neovim session, which is all we need: they exist to correlate an
--- extmark with the node it identifies.
function M.next_id()
  id_counter = id_counter + 1
  return "n" .. id_counter
end

return M
