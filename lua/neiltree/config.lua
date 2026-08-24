local M = {}

M.defaults = {
  -- show dotfiles by default
  show_hidden = false,
  -- recursively expand every directory when opening a tree
  expand_all = false,
  -- render nvim-web-devicons (if installed) / simple fallback icons
  icons = true,
  -- ask for confirmation before applying create/delete/move to disk
  confirm_changes = true,
  -- keep the tree in sync with disk on its own: watch every rendered
  -- directory for changes, and rescan when you enter the buffer or return
  -- to Neovim. Never touches a buffer with unsaved edits (it would have to
  -- discard them) - that case still waits for `:w` or the refresh keymap.
  auto_refresh = true,
  -- fixed width of the `sidebar = true` / `--sidebar` window
  sidebar_width = 30,
  -- which side the sidebar opens on: "left" or "right"
  sidebar_side = "left",
  -- extensions opened with the OS's default application instead of as a
  -- text buffer (set an entry to `false` in setup() to remove it, or add
  -- your own). Lowercase, no leading dot.
  external_extensions = {
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    bmp = true,
    webp = true,
    ico = true,
    tiff = true,
    tif = true,
    pdf = true,
    mp4 = true,
    mov = true,
    mkv = true,
    avi = true,
    webm = true,
    mp3 = true,
    wav = true,
    flac = true,
    ogg = true,
  },
  keymaps = {
    select = "<CR>", -- open file, or toggle directory
    expand = "l", -- expand directory under cursor
    collapse = "h", -- collapse directory under cursor / go to parent
    parent_dir = "-", -- move cursor to the parent line
    refresh = "R", -- rescan from disk, discarding unsaved buffer edits
    cut = "x", -- queue the node(s) under cursor / visual selection to move
    paste = "p", -- move queued node(s) into the directory under cursor
    close = "q",
    help = "g?",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
