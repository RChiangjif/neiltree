local fs = require("neiltree.fs")

local M = {}

--- Human-readable lines describing `ops`, for the confirmation prompt.
function M.summarize(ops)
  local lines = {}
  for _, node in ipairs(ops.deletes) do
    table.insert(lines, ("DELETE  %s%s"):format(node.path, node.type == "directory" and "/" or ""))
  end
  for _, mv in ipairs(ops.moves) do
    table.insert(lines, ("MOVE    %s%s -> %s"):format(mv.old_path, mv.is_dir and "/" or "", mv.new_path))
  end
  for _, c in ipairs(ops.creates) do
    table.insert(lines, ("CREATE  %s%s"):format(c.path, c.is_dir and "/" or ""))
  end
  return lines
end

--- Apply `ops` to disk. Order: deletes, then moves, then creates (shallowest
--- path first within each group). Returns a list of error strings (empty on
--- full success); best-effort continues past individual failures so one bad
--- operation doesn't strand the rest half-applied.
function M.run(ops)
  local errors = {}

  for _, node in ipairs(ops.deletes) do
    local ok, err = fs.rmrf(node.path)
    if not ok then
      table.insert(errors, ("delete %s: %s"):format(node.path, err))
    end
  end

  for _, mv in ipairs(ops.moves) do
    local ok, err = fs.move(mv.old_path, mv.new_path)
    if not ok then
      table.insert(errors, ("move %s -> %s: %s"):format(mv.old_path, mv.new_path, err))
    end
  end

  table.sort(ops.creates, function(a, b)
    return #a.path < #b.path
  end)
  for _, c in ipairs(ops.creates) do
    local ok, err
    if c.is_dir then
      ok, err = fs.mkdirp(c.path)
    else
      ok, err = fs.create_file(c.path)
    end
    if not ok then
      table.insert(errors, ("create %s: %s"):format(c.path, err))
    end
  end

  return errors
end

return M
