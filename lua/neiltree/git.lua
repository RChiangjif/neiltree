local config = require("neiltree.config")

local M = {}

-- A `git` call that hasn't answered by now is not going to: a contended
-- `index.lock`, a dead NFS mount, a credential helper waiting on a prompt
-- that will never come. Failing visibly beats a panel that stays blank.
local TIMEOUT_MS = 10000

--- Run `git <args>` with `dir` as the working directory. Never throws: a
--- spawn failure (no `git` on PATH, `dir` deleted underneath us) comes back
--- through `cb` like any other failure, so callers have exactly one error
--- path. `cb` always runs on the main loop, so callers never have to think
--- about libuv's fast-event context.
--- @param cb fun(ok: boolean, stdout: string, stderr: string, code: integer)
local function run(dir, args, cb)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { cwd = dir, text = true, timeout = TIMEOUT_MS }, function(res)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "", res.stderr or "", res.code)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "", tostring(err), -1)
    end)
  end
end

local function fail_message(stderr, fallback)
  local msg = vim.trim(stderr or "")
  if msg == "" then
    return fallback
  end
  return (msg:gsub("\n.*$", ""))
end

--- @param common string `--git-common-dir`, which git reports *relative to
--- the directory the command ran in* (".git" from the toplevel, "../.git"
--- from a subdirectory) - so it has to be resolved against `dir`, not
--- against Neovim's cwd the way `vim.fs.abspath` would.
local function resolve_common(dir, common)
  if common:sub(1, 1) ~= "/" then
    common = dir .. "/" .. common
  end
  return vim.fs.normalize(common)
end

--- Locate the repository containing `dir`.
---
--- Deliberately asks git rather than walking up looking for a `.git`
--- *directory*: in a submodule and in a linked worktree `.git` is a plain
--- file pointing elsewhere, and both are cases this panel has to get right.
--- `--git-common-dir` matters separately from `--absolute-git-dir`, because
--- in a linked worktree HEAD and the index live in the latter while
--- `refs/heads` lives in the former - watch only one and the branch list
--- never updates.
--- @param cb fun(repo: table|nil, err: string|nil)
function M.resolve(dir, cb)
  run(dir, { "rev-parse", "--absolute-git-dir", "--git-common-dir", "--is-bare-repository", "--show-toplevel" }, function(ok, out, stderr)
    if ok then
      local f = vim.split(vim.trim(out), "\n", { plain = true })
      cb({
        git_dir = vim.fs.normalize(f[1]),
        common_dir = resolve_common(dir, f[2]),
        bare = false,
        root = vim.fs.normalize(f[4]),
      })
      return
    end
    -- In a bare repository `--show-toplevel` is fatal, which aborts the
    -- whole invocation - so a failure here isn't yet "not a repository".
    run(dir, { "rev-parse", "--absolute-git-dir", "--git-common-dir" }, function(ok2, out2, stderr2)
      if not ok2 then
        cb(nil, fail_message(stderr2 ~= "" and stderr2 or stderr, "not a git repository"))
        return
      end
      local f = vim.split(vim.trim(out2), "\n", { plain = true })
      local git_dir = vim.fs.normalize(f[1])
      cb({ git_dir = git_dir, common_dir = resolve_common(dir, f[2]), bare = true, root = git_dir })
    end)
  end)
end

-- `--no-optional-locks` is not optional: a plain `git status` refreshes and
-- rewrites the index, the fs_event watching the git dir sees that write, and
-- the refresh it schedules runs `git status` again - a refresh loop at the
-- debounce interval, forever.
-- `-z` gives NUL-separated records with no quoting at all, so paths with
-- spaces or UTF-8 need no un-escaping; `status.relativePaths=false` pins
-- paths to the repo root regardless of cwd; `-unormal` collapses a wholly
-- untracked directory to a single `dir/` row, which is the right density for
-- a narrow panel (and the difference between one row and ten thousand after
-- an `rm -rf node_modules`).
local STATUS_ARGS = {
  "--no-optional-locks",
  "-c",
  "status.relativePaths=false",
  "status",
  "--porcelain=v2",
  "--branch",
  "--untracked-files=normal",
  "--ignored=no",
  "-z",
}

local function add_change(data, xy, path, orig)
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  -- A file can legitimately land in both buckets (`MM` = staged edits plus
  -- further unstaged ones); `git status` lists it twice too.
  if x ~= "." then
    table.insert(data.staged, { code = x, path = path, orig = orig })
  end
  if y ~= "." then
    table.insert(data.unstaged, { code = y, path = path })
  end
end

local function parse_status(out, data)
  local recs = vim.split(out, "\0", { plain = true })
  local i = 1
  while i <= #recs do
    local rec = recs[i]
    i = i + 1
    local tag = rec:sub(1, 2)
    if rec == "" then -- the trailing NUL leaves one empty element
      goto continue
    elseif tag == "# " then
      local key, val = rec:match("^# (%S+) (.*)$")
      if key == "branch.oid" then
        if val == "(initial)" then
          data.head.unborn = true
        else
          data.head.oid = val:sub(1, 8)
        end
      elseif key == "branch.head" then
        if val == "(detached)" then
          data.head.detached = true
        else
          data.head.branch = val
        end
      elseif key == "branch.upstream" then
        data.head.upstream = val
      elseif key == "branch.ab" then
        local a, b = val:match("^%+(%d+) %-(%d+)$")
        data.head.ahead, data.head.behind = tonumber(a), tonumber(b)
      end
    elseif tag == "1 " then
      local xy, path = rec:match("^1 (..) %S+ %d+ %d+ %d+ %S+ %S+ (.*)$")
      if xy then
        add_change(data, xy, path)
      end
    elseif tag == "2 " then
      local xy, path = rec:match("^2 (..) %S+ %d+ %d+ %d+ %S+ %S+ %S+ (.*)$")
      -- Under `-z` a rename's two paths are separate NUL-terminated fields
      -- rather than one tab-joined one, so the original path is the *next*
      -- record. Miss this and every record after the first rename is read
      -- as the wrong type.
      local orig = recs[i]
      i = i + 1
      if xy then
        add_change(data, xy, path, orig)
      end
    elseif tag == "u " then
      local xy, path = rec:match("^u (..) %S+ %d+ %d+ %d+ %d+ %S+ %S+ %S+ (.*)$")
      if xy then
        table.insert(data.conflicts, { code = xy, path = path })
      end
    elseif tag == "? " then
      table.insert(data.untracked, { code = "?", path = rec:sub(3) })
    end
    ::continue::
  end

  -- porcelain v2 drops `# branch.ab` when the upstream ref itself is gone,
  -- while still printing `# branch.upstream`. That combination is the only
  -- signal it gives for "your upstream has been deleted".
  data.head.upstream_gone = data.head.upstream ~= nil and data.head.ahead == nil
end

-- Tab-separated: ref names cannot contain ASCII control characters (see
-- `git check-ref-format`), so a tab can never appear inside one.
-- `%(worktreepath)` goes last as the only field that could contain one.
local REF_FORMAT = table.concat({
  "%(refname)",
  "%(HEAD)",
  "%(refname:short)",
  "%(upstream:short)",
  "%(upstream:trackshort)",
  "%(objectname:short=8)",
  "%(symref)",
  "%(worktreepath)",
}, "%09")

local function parse_refs(out, data, repo)
  local rows = {}
  local remotes = {}
  for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
    if line ~= "" then
      local f = vim.split(line, "\t", { plain = true })
      table.insert(rows, f)
      local name = f[1]:match("^refs/remotes/([^/]+)/")
      if name then
        remotes[name] = true
      end
    end
  end

  for _, f in ipairs(rows) do
    local refname, head, short, upstream, track, oid, symref, worktree =
      f[1], f[2], f[3], f[4] or "", f[5] or "", f[6] or "", f[7] or "", f[8] or ""
    -- A non-empty symref is `refs/remotes/origin/HEAD`: an alias for another
    -- row, not a branch of its own.
    if symref == "" then
      if refname:sub(1, 11) == "refs/heads/" then
        table.insert(data.locals, {
          name = short,
          current = head == "*",
          upstream = upstream ~= "" and upstream or nil,
          track = track,
          oid = oid,
          -- Non-empty and not us means the branch is checked out in another
          -- worktree, where `git switch` will refuse to touch it.
          worktree = (worktree ~= "" and worktree ~= repo.root) and worktree or nil,
        })
      elseif refname:sub(1, 13) == "refs/remotes/" then
        local remote, branch = short:match("^([^/]+)/(.+)$")
        if remote and remotes[remote] then
          table.insert(data.remotes, { name = short, remote = remote, branch = branch, oid = oid })
        end
      end
    end
  end
end

--- Gather everything the panel renders, in two concurrent `git` calls.
--- @param cb fun(data: table|nil, err: string|nil)
function M.collect(repo, cb)
  local data = {
    bare = repo.bare,
    head = {},
    conflicts = {},
    staged = {},
    unstaged = {},
    untracked = {},
    locals = {},
    remotes = {},
  }
  -- A bare repository has no working tree to have a status.
  local pending = repo.bare and 1 or 2
  local err

  local function done()
    pending = pending - 1
    if pending == 0 then
      if err then
        cb(nil, err)
      else
        cb(data)
      end
    end
  end

  if not repo.bare then
    run(repo.root, STATUS_ARGS, function(ok, out, stderr)
      if ok then
        parse_status(out, data)
      else
        err = err or fail_message(stderr, "git status failed")
      end
      done()
    end)
  end

  run(repo.root, {
    "--no-optional-locks",
    "for-each-ref",
    "--sort=-committerdate",
    "--format=" .. REF_FORMAT,
    "refs/heads",
    "refs/remotes",
  }, function(ok, out, stderr)
    if ok then
      parse_refs(out, data, repo)
    else
      err = err or fail_message(stderr, "git for-each-ref failed")
    end
    done()
  end)
end

--- Switch branches. `spec.ref` is always fully qualified for a remote
--- (`origin/foo`, with `track`), never the bare branch name: `git switch foo`
--- is ambiguous the moment two remotes both have a `foo`, whereas
--- `git switch --track origin/foo` never is.
--- @param spec { ref: string, track: boolean|nil, detach: boolean|nil }
--- @param cb fun(ok: boolean, stderr: string)
function M.switch(repo, spec, cb)
  local args = { "switch" }
  if spec.detach then
    table.insert(args, "--detach")
  end
  if spec.track then
    table.insert(args, "--track")
  end
  table.insert(args, spec.ref)
  run(repo.root, args, function(ok, _, stderr)
    cb(ok, stderr)
  end)
end

--- How many rows a section renders before the rest go behind a "... N more".
function M.max_rows()
  local n = config.options.git.max_rows
  return (type(n) == "number" and n > 0) and n or math.huge
end

return M
