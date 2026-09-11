local config = require("neiltree.config")

--- Building a rendered line out of `put` segments, so highlight columns come
--- out as correct byte offsets for free. Doing that arithmetic by hand is
--- easy to get subtly wrong in a view full of multi-byte glyphs, and both the
--- git panel and the commit graph are exactly that.
local M = {}

local NERD =
  { open = "▾", closed = "▸", up = "↑", down = "↓", sync = "≡", diverged = "↕", arrow = "↳", ellipsis = "…" }
local ASCII =
  { open = "v", closed = ">", up = "+", down = "-", sync = "=", diverged = "~", arrow = "->", ellipsis = "..." }

--- Reuses the existing `icons` option rather than adding a second one: a
--- terminal without a Nerd Font has the same problem with both.
function M.sym()
  return config.options.icons and NERD or ASCII
end

function M.ascii()
  return not config.options.icons
end

function M.new()
  return { text = "", marks = {} }
end

function M.put(l, text, hl)
  if text ~= "" then
    if hl then
      table.insert(l.marks, { col = #l.text, end_col = #l.text + #text, hl = hl })
    end
    l.text = l.text .. text
  end
  return l
end

--- Pad `l` so a `tail_cells`-wide tail lands flush against `width`.
function M.pad_to(l, width, tail_cells)
  local gap = width - vim.fn.strdisplaywidth(l.text) - tail_cells
  return M.put(l, string.rep(" ", math.max(gap, 1)))
end

--- Pad `l` out to exactly `cells` display columns (no-op if already past it).
function M.pad_col(l, cells)
  local gap = cells - vim.fn.strdisplaywidth(l.text)
  return M.put(l, string.rep(" ", math.max(gap, 0)))
end

--- Shrink `s` to at most `cells` *display columns*. `mode` "tail" keeps the
--- start and marks the cut at the end - right for branch names, whose
--- prefixes (`fix/`, `feat/`, `user/`) are how you scan a list. "head" keeps
--- the end - right for paths, where the basename is the discriminator.
--- Display-cell rather than byte arithmetic, since branch names, paths and
--- commit subjects are routinely non-ASCII.
function M.truncate(s, cells, mode)
  if cells <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= cells then
    return s
  end
  local mark = M.sym().ellipsis
  local budget = cells - vim.fn.strdisplaywidth(mark)
  if budget <= 0 then
    return ""
  end
  local n = vim.fn.strchars(s)
  if mode == "head" then
    for i = 1, n do
      local part = vim.fn.strcharpart(s, i)
      if vim.fn.strdisplaywidth(part) <= budget then
        return mark .. part
      end
    end
    return mark
  end
  for len = n, 1, -1 do
    local part = vim.fn.strcharpart(s, 0, len)
    if vim.fn.strdisplaywidth(part) <= budget then
      return part .. mark
    end
  end
  return mark
end

return M
