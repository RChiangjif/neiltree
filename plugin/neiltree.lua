if vim.g.loaded_neiltree then
  return
end
vim.g.loaded_neiltree = true

vim.api.nvim_create_user_command("Neiltree", function(cmd_opts)
  local float, sidebar, git = false, false, false
  local args = {}
  for _, arg in ipairs(cmd_opts.fargs) do
    if arg == "--float" then
      float = true
    elseif arg == "--sidebar" then
      sidebar = true
    elseif arg == "--git" then
      git = true
    else
      table.insert(args, arg)
    end
  end
  local path = #args > 0 and table.concat(args, " ") or nil
  if git then
    require("neiltree").toggle_git(path)
  elseif sidebar then
    require("neiltree").toggle_sidebar(path)
  else
    require("neiltree").open(path, { float = float })
  end
end, {
  nargs = "*",
  complete = "dir",
  desc = "Open neiltree at [path] (default cwd); --float for a floating window, --sidebar to toggle a pinned sidebar, --git to toggle the git panel in that same sidebar",
})
