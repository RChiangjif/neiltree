local config = require("neiltree.config")

local devicons_ok, devicons = pcall(require, "nvim-web-devicons")

local M = {}

-- Built from codepoints (Nerd Font: nf-fa-folder / nf-fa-folder_open /
-- nf-fa-file) via nr2char rather than as literal characters in the source,
-- since private-use-area glyphs like these are prone to getting mangled by
-- editors/terminals that don't round-trip them exactly.
local DIR_ICON_CLOSED = vim.fn.nr2char(0xf07b, true)
local DIR_ICON_OPEN = vim.fn.nr2char(0xf07c, true)
local FILE_ICON = vim.fn.nr2char(0xf15b, true)

local function icon_for(node)
  if not config.options.icons then
    return nil, nil
  end
  if node.type == "directory" then
    return node.expanded and DIR_ICON_OPEN or DIR_ICON_CLOSED, "NeiltreeDirIcon"
  end
  if devicons_ok then
    local icon, hl = devicons.get_icon(node.name, node.name:match("%.([^.]+)$"), { default = true })
    return icon, hl
  end
  return FILE_ICON, "NeiltreeFileIcon"
end

--- Text of the editable buffer line for `node` (no icon - that's pure
--- decoration, added separately as inline virtual text, so that the real
--- buffer text stays exactly "<tabs><name>[/]" and is trivial and robust
--- to parse back out on save). One tab character per depth level - see
--- the module comment for why tabs rather than spaces.
function M.line_text(node)
  local indent = string.rep("\t", node.depth)
  local suffix = node.type == "directory" and "/" or ""
  return indent .. node.name .. suffix
end

--- Place (or replace) the identity + decoration extmarks for `node`, which
--- must already occupy buffer line `row` (0-indexed).
function M.place_marks(st, node, row, text)
  local bufnr = st.bufnr
  -- right_gravity=true (for both ends) is what makes a node's mark shift
  -- down correctly when a *sibling* is inserted directly above it (e.g. a
  -- neighboring directory being expanded) - with right_gravity=false the
  -- insertion is instead absorbed as "belonging before" the mark and it
  -- does not move, which desyncs row-to-node lookups for every following
  -- line. invalidate+undo_restore=false is what makes the mark actually
  -- disappear (not just hide, restorable via undo) when its whole line is
  -- deleted - that disappearance is exactly our delete-detection signal.
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, st.ns, row, 0, {
    end_row = row,
    end_col = #text,
    right_gravity = true,
    end_right_gravity = true,
    invalidate = true,
    undo_restore = false,
    hl_group = node.type == "directory" and "NeiltreeDirName" or nil,
  })
  node.mark_id = mark_id
  st.mark_to_node[mark_id] = node

  local name_col = node.depth
  local icon, icon_hl = icon_for(node)
  if icon and icon ~= "" then
    -- Same end_row/end_col/invalidate treatment as the identity mark above,
    -- so the icon disappears together with the line instead of surviving
    -- (with no range/invalidate, a plain point extmark just slides onto
    -- whatever line ends up nearby when its line is deleted - by collapse
    -- or by `dd` - which is what caused icons to "stack" on repeated
    -- expand/collapse: every deleted child left its icon mark behind).
    node.decor_mark_id = vim.api.nvim_buf_set_extmark(bufnr, st.ns, row, name_col, {
      id = node.decor_mark_id,
      end_row = row,
      end_col = #text,
      right_gravity = true,
      end_right_gravity = true,
      invalidate = true,
      undo_restore = false,
      virt_text = { { icon .. " ", icon_hl or "NeiltreeFileIcon" } },
      virt_text_pos = "inline",
    })
  elseif node.decor_mark_id then
    vim.api.nvim_buf_del_extmark(bufnr, st.ns, node.decor_mark_id)
    node.decor_mark_id = nil
  end
end

--- Full rebuild of the buffer from the in-memory tree. Discards any
--- unsaved edits in the buffer. Only used for the initial open and for a
--- post-save / manual / automatic refresh, where that is exactly what we
--- want. Returns the nodes in the order they were rendered, so the caller
--- can map a path back to its new line.
function M.full(st)
  local bufnr = st.bufnr
  local lines = {}
  local order = {}

  local function walk(nodes)
    for _, node in ipairs(nodes) do
      table.insert(order, node)
      table.insert(lines, M.line_text(node))
      if node.type == "directory" and node.expanded and node.loaded then
        walk(node.children)
      end
    end
  end
  walk(st.root.children or {})

  vim.bo[bufnr].modifiable = true
  -- Replacing every line would otherwise leave an undoable state whose text
  -- no longer matches any of the extmarks we're about to place, so a stray
  -- `u` after a refresh would resurrect lines the tree no longer knows
  -- about. 'undolevels' = -1 across the change is the standard way to keep
  -- it out of the undo history (-123456 means "no local value", so
  -- round-tripping the local scope restores whatever was there).
  local undolevels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr, scope = "local" })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr, scope = "local" })
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("undolevels", undolevels, { buf = bufnr, scope = "local" })
  if not ok then
    error(err)
  end

  vim.api.nvim_buf_clear_namespace(bufnr, st.ns, 0, -1)
  st.mark_to_node = {}

  for row, node in ipairs(order) do
    M.place_marks(st, node, row - 1, lines[row])
  end

  vim.bo[bufnr].modified = false
  return order
end

--- Insert freshly-loaded `node.children` as new lines directly below
--- `node`'s current line, without touching any other line in the buffer
--- (so unrelated unsaved edits elsewhere are preserved).
function M.insert_children(st, node)
  local bufnr = st.bufnr
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, st.ns, node.mark_id, {})
  local row = pos[1]

  local lines = {}
  for _, child in ipairs(node.children) do
    table.insert(lines, M.line_text(child))
  end

  vim.bo[bufnr].modifiable = true
  local was_modified = vim.bo[bufnr].modified
  vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 1, false, lines)

  for i, child in ipairs(node.children) do
    M.place_marks(st, child, row + i, lines[i])
  end
  vim.bo[bufnr].modified = was_modified
end

--- Remove every currently-rendered descendant line of `node` (used when
--- collapsing). Lines that were typed by the user under `node` but never
--- corresponded to a loaded node (no mark) are intentionally left alone;
--- the save-time validator will flag them if they end up inconsistently
--- indented.
function M.remove_descendants(st, node)
  local bufnr = st.bufnr
  local rows = {}

  local function collect(n)
    if not n.children then
      return
    end
    for _, child in ipairs(n.children) do
      if child.mark_id then
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, st.ns, child.mark_id, {})
        table.insert(rows, pos[1])
        st.mark_to_node[child.mark_id] = nil
        child.mark_id = nil
        child.decor_mark_id = nil
      end
      collect(child)
    end
  end
  collect(node)

  table.sort(rows, function(a, b)
    return a > b
  end)

  vim.bo[bufnr].modifiable = true
  local was_modified = vim.bo[bufnr].modified
  for _, row in ipairs(rows) do
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, {})
  end
  vim.bo[bufnr].modified = was_modified
end

--- Refresh just `node`'s decoration (icon) in place - used after toggling
--- expanded state to flip the folder icon. The editable text never depends
--- on `expanded`, so buffer text and the identity extmark are untouched.
function M.update_decoration(st, node)
  local bufnr = st.bufnr
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, st.ns, node.mark_id, { details = true })
  local row, end_col = pos[1], pos[3].end_col
  local name_col = node.depth
  local icon, icon_hl = icon_for(node)
  if icon and icon ~= "" then
    node.decor_mark_id = vim.api.nvim_buf_set_extmark(bufnr, st.ns, row, name_col, {
      id = node.decor_mark_id,
      end_row = row,
      end_col = end_col,
      right_gravity = true,
      end_right_gravity = true,
      invalidate = true,
      undo_restore = false,
      virt_text = { { icon .. " ", icon_hl or "NeiltreeFileIcon" } },
      virt_text_pos = "inline",
    })
  end
end

return M
