local uv = vim.uv or vim.loop

local M = {}

--- List the entries of a directory.
--- @return table[] entries {name=string, type="file"|"directory"|"link"}
--- @return string|nil err
function M.scandir(path, opts)
  opts = opts or {}
  local fd, err = uv.fs_scandir(path)
  if not fd then
    return {}, ("failed to read directory %s: %s"):format(path, err or "?")
  end
  local entries = {}
  while true do
    local name, ftype = uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if opts.show_hidden or name:sub(1, 1) ~= "." then
      if not ftype or ftype == "unknown" then
        local stat = uv.fs_lstat(path .. "/" .. name)
        ftype = stat and stat.type or "file"
      end
      table.insert(entries, { name = name, type = ftype })
    end
  end
  table.sort(entries, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)
  return entries, nil
end

--- Recursively create a directory (like `mkdir -p`).
function M.mkdirp(path)
  if path == "" or path == "/" then
    return true
  end
  local stat = uv.fs_lstat(path)
  if stat then
    if stat.type == "directory" then
      return true
    end
    return false, ("not a directory: %s"):format(path)
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    local ok, err = M.mkdirp(parent)
    if not ok then
      return false, err
    end
  end
  local ok, err = uv.fs_mkdir(path, 493) -- 0755
  if not ok then
    -- Tolerate a race where the directory appeared concurrently.
    local st = uv.fs_lstat(path)
    if st and st.type == "directory" then
      return true
    end
    return false, err
  end
  return true
end

--- Create an empty file. Ensures the parent directory exists first.
--- Fails if the file already exists.
function M.create_file(path)
  local ok, err = M.mkdirp(vim.fs.dirname(path))
  if not ok then
    return false, err
  end
  local fd, ferr = uv.fs_open(path, "wx", 420) -- 0644
  if not fd then
    return false, ferr
  end
  uv.fs_close(fd)
  return true
end

--- Recursively remove a file or directory.
function M.rmrf(path)
  local stat = uv.fs_lstat(path)
  if not stat then
    return true
  end
  if stat.type == "directory" then
    local fd, err = uv.fs_scandir(path)
    if not fd then
      return false, err
    end
    while true do
      local name = uv.fs_scandir_next(fd)
      if not name then
        break
      end
      local ok, rerr = M.rmrf(path .. "/" .. name)
      if not ok then
        return false, rerr
      end
    end
    local ok, err2 = uv.fs_rmdir(path)
    if not ok then
      return false, err2
    end
    return true
  end
  local ok, err3 = uv.fs_unlink(path)
  if not ok then
    return false, err3
  end
  return true
end

--- Move/rename a file or directory. Ensures the destination's parent
--- directory exists first.
function M.move(old, new)
  local ok, err = M.mkdirp(vim.fs.dirname(new))
  if not ok then
    return false, err
  end
  if uv.fs_lstat(new) then
    return false, ("destination already exists: %s"):format(new)
  end
  local ok2, err2 = uv.fs_rename(old, new)
  if not ok2 then
    return false, err2
  end
  return true
end

function M.exists(path)
  return uv.fs_lstat(path) ~= nil
end

return M
