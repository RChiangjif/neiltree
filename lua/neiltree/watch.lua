local config = require("neiltree.config")

local M = {}

local uv = vim.uv

-- One OS-level watcher per expanded directory adds up fast on a deeply
-- expanded tree, and every platform caps how many a process may hold
-- (`fs.inotify.max_user_watches` on Linux). Past this many directories we
-- simply stop adding watchers; the BufEnter/FocusGained catch-up refresh in
-- ui.lua still picks those directories up the next time you look at the
-- tree.
local MAX_WATCHERS = 512

-- Filesystem events arrive in bursts (a `git checkout` touching a hundred
-- files, an editor writing a temp file and renaming it into place), so
-- collapse everything landing within this window into a single rescan.
local DEBOUNCE_MS = 100

--- Every directory whose contents are currently rendered: the root, plus
--- each expanded subdirectory. Watching is deliberately non-recursive (the
--- recursive libuv flag only exists on macOS/Windows anyway) - a change
--- deeper than what's on screen can't alter a single rendered line.
local function watched_dirs(st)
  local dirs = { st.root.path }
  local function walk(node)
    if not node.children then
      return
    end
    for _, child in ipairs(node.children) do
      if child.type == "directory" and child.expanded and child.loaded then
        table.insert(dirs, child.path)
        walk(child)
      end
    end
  end
  walk(st.root)
  return dirs
end

local function close_handle(handle)
  pcall(function()
    handle:stop()
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

local function schedule_refresh(st)
  if not st.watch_timer then
    st.watch_timer = uv.new_timer()
    if not st.watch_timer then
      return
    end
  end
  -- Re-arming an already-running timer restarts it, which is exactly the
  -- debounce we want: the rescan happens DEBOUNCE_MS after the *last* event
  -- of a burst, not once per event.
  st.watch_timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      require("neiltree.ui").auto_refresh(st)
    end)
  end)
end

--- Bring `st`'s watchers in line with what the buffer currently shows:
--- start one for every newly expanded directory, drop the ones that were
--- collapsed or have gone away. Cheap and idempotent - call it after any
--- change to the visible tree.
function M.sync(st)
  if not config.options.auto_refresh then
    M.detach(st)
    return
  end

  st.watchers = st.watchers or {}

  local wanted = {}
  local count = 0
  for _, dir in ipairs(watched_dirs(st)) do
    if count >= MAX_WATCHERS then
      break
    end
    if not wanted[dir] then
      wanted[dir] = true
      count = count + 1
    end
  end

  for dir, handle in pairs(st.watchers) do
    if not wanted[dir] then
      close_handle(handle)
      st.watchers[dir] = nil
    end
  end

  for dir in pairs(wanted) do
    if not st.watchers[dir] then
      local handle = uv.new_fs_event()
      -- Watching can legitimately fail (the directory was removed between
      -- the scan and here, or the filesystem has no change notifications at
      -- all - a network mount, or /mnt/... under WSL). Nothing to report:
      -- the catch-up refresh covers those directories.
      local ok = handle
        and pcall(function()
          handle:start(dir, {}, function()
            schedule_refresh(st)
          end)
        end)
      if ok then
        st.watchers[dir] = handle
      elseif handle then
        close_handle(handle)
      end
    end
  end
end

--- Stop watching entirely (buffer wiped, or `auto_refresh` turned off).
function M.detach(st)
  for dir, handle in pairs(st.watchers or {}) do
    close_handle(handle)
    st.watchers[dir] = nil
  end
  if st.watch_timer then
    pcall(function()
      st.watch_timer:stop()
      if not st.watch_timer:is_closing() then
        st.watch_timer:close()
      end
    end)
    st.watch_timer = nil
  end
end

return M
