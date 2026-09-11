local config = require("neiltree.config")
local git = require("neiltree.git")

--- Switching branches, and every consequence of having done so. Shared by
--- the sidebar panel and the commit graph: both can be open at once, so the
--- confirmation policy, the in-flight guard and the post-switch cleanup all
--- have to be one implementation rather than two that drift.
local M = {}

-- Process-wide, not per-view: two open views must not both be mid-switch.
local running = false

function M.busy()
  return running
end

--- @param spec table as `git.switch` - `{ ref, track?, detach? }`
--- @param label string human name for the target, used in prompts and messages
--- @param dirty integer how many files have local changes (the caller
---   already knows this; it decides whether we prompt)
--- @param cb fun(ok: boolean)|nil run once everything has settled
--- @return boolean started - false when refused or cancelled, so the caller
---   can skip painting an "in progress" state that will never clear
function M.switch(repo, spec, label, dirty, cb)
  if running then
    vim.notify("[neiltree] a git operation is already running", vim.log.levels.WARN)
    return false
  end

  -- A clean tree switches straight away: that is cheap and trivially undone,
  -- and prompting every time would train you to hit Yes without reading. A
  -- dirty one is the case worth stopping for, since git will either carry the
  -- changes across or refuse outright.
  if config.options.confirm_changes and dirty > 0 then
    local msg = ("neiltree: switch to %s?\n\n  %d file(s) have local changes - git will carry them\n  over, or refuse the switch."):format(
      label,
      dirty
    )
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      vim.notify("[neiltree] switch cancelled", vim.log.levels.WARN)
      return false
    end
  end

  running = true
  git.switch(repo, spec, function(ok, stderr)
    running = false
    if ok then
      vim.notify(("[neiltree] switched to %s"):format(label), vim.log.levels.INFO)
      -- The working tree just changed under every open buffer and every open
      -- tree. Nothing else does this, and without it you go on editing
      -- content from the branch you left.
      pcall(vim.cmd, "checktime")
      require("neiltree.ui").refresh_all_trees()
    else
      local msg = vim.trim(stderr or "")
      vim.notify("[neiltree] " .. (msg ~= "" and msg or "git switch failed"), vim.log.levels.ERROR)
    end
    if cb then
      cb(ok)
    end
  end)
  return true
end

--- Work out the `git switch` invocation that lands you on `branch`, given the
--- local branches that exist. `remote_ref` is set when the row you picked was
--- a remote one (`origin/foo`), which is what decides whether a local
--- tracking branch has to be created.
--- Returns `spec, label`, or nil when the user cancelled the ambiguity prompt.
function M.spec_for(branch, remote_ref, locals)
  if not remote_ref then
    return { ref = branch }, branch
  end

  local existing
  for _, b in ipairs(locals) do
    if b.name == branch then
      existing = b
      break
    end
  end
  if not existing then
    -- `--track <remote>/<branch>` rather than a bare `git switch <branch>`:
    -- the bare form is ambiguous the moment two remotes both have a branch
    -- of that name, the qualified one never is.
    return { ref = remote_ref, track = true }, ("%s (tracking %s)"):format(branch, remote_ref)
  end
  if existing.upstream == remote_ref then
    return { ref = branch }, branch
  end
  local choice = vim.fn.confirm(
    ("neiltree: local '%s' already exists and tracks %s, not %s."):format(
      branch,
      existing.upstream or "nothing",
      remote_ref
    ),
    ("&Switch to local %s\n&Detach at %s\n&Cancel"):format(branch, remote_ref),
    3
  )
  if choice == 1 then
    return { ref = branch }, branch
  elseif choice == 2 then
    return { ref = remote_ref, detach = true }, remote_ref .. " (detached)"
  end
  return nil
end

return M
