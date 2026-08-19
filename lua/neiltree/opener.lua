local config = require("neiltree.config")

local M = {}

function M.is_external(path)
  local ext = path:match("%.([^./]+)$")
  return ext ~= nil and config.options.external_extensions[ext:lower()] == true
end

--- Hand `path` off to the OS's default application for it, without
--- blocking Neovim. Best-effort: `explorer.exe` in particular is known to
--- report a nonzero exit code on WSL even when it succeeds, so failures
--- are only surfaced where the exit code is actually meaningful.
function M.open(path)
  local cmd, code_is_meaningful
  if vim.fn.has("wsl") == 1 then
    local winpath = vim.trim(vim.fn.system({ "wslpath", "-w", path }))
    cmd, code_is_meaningful = { "explorer.exe", winpath }, false
  elseif vim.fn.has("mac") == 1 then
    cmd, code_is_meaningful = { "open", path }, true
  elseif vim.fn.has("win32") == 1 then
    cmd, code_is_meaningful = { "cmd.exe", "/c", "start", "", path }, false
  else
    cmd, code_is_meaningful = { "xdg-open", path }, true
  end

  local ok, err = pcall(vim.system, cmd, { detach = true }, function(result)
    if code_is_meaningful and result.code ~= 0 then
      vim.schedule(function()
        vim.notify(("[neiltree] failed to open '%s' externally (exit %d)"):format(path, result.code), vim.log.levels.ERROR)
      end)
    end
  end)
  if not ok then
    vim.notify(("[neiltree] could not open '%s' externally: %s"):format(path, err), vim.log.levels.ERROR)
  end
end

return M
