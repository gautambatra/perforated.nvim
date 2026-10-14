--- Stacked pop-ups: the one in use stands out, the ones under it step back.
---
---   * active — the focused pop-up (or an open modal menu, which reads keys without taking
---     focus): its border in the theme's accent colour (`PerforatedFloatBorderActive`, linked
---     to `FloatTitle`);
---   * dim    — every other pop-up while one is active: text and border dimmed;
---   * plain  — no pop-up in use (the cursor is in a normal window): the usual look.
---
--- Active and plain only swap the border in 'winhighlight'. Dim needs every colour in the
--- window changed (syntax, extmarks, the cursor line), which only a highlight namespace can do:
--- one namespace in which every group is the dimmed text colour, built from the theme on first
--- use and again after a colorscheme change. While a window has a namespace its 'winhighlight'
--- is ignored, so the namespace also gives the background and the border.
---
--- Leaving dim can't go back to the 'winhighlight': on Neovim 0.11 a window whose namespace was
--- ever set (even to 0) ignores its 'winhighlight' for good (0.12 only until it is set again).
--- So a pop-up that has been dimmed gets a namespace made of its 'winhighlight' instead (one
--- per distinct string, its pairs as links; other groups fall back to the global ones), and one
--- never dimmed is left alone.
---
--- Pop-ups opt in with `register(win, opts)` right after setting their 'winhighlight'. Toasts
--- (never focused, own coloured borders) and the hunk preview (gone on the next cursor move)
--- don't.

local M = {}

---@class perforated.StackEntry
---@field group any        windows of one pop-up (the picker's filter, list and preview)
---@field modal boolean?   active while open, focused or not (action menus)
---@field base string      the pop-up's own 'winhighlight'
---@field active string    the same with the accent border
---@field seq integer      registration order: the newest modal wins
---@field state string?    'active' | 'dim' | 'plain' (as applied)
---@field dimmed boolean?  its namespace has been set ('winhighlight' alone no longer applies)

local entries = {} ---@type table<integer, perforated.StackEntry>
local seq = 0
local ns ---@type integer?
local built = false
local winhl_ns = {} ---@type table<string, integer>

--- A namespace standing in for a 'winhighlight' value: `From:To` pairs as links.
---@param winhl string
---@return integer
local function ns_of(winhl)
  if not winhl_ns[winhl] then
    local id = vim.api.nvim_create_namespace('perforated.stack.winhl.' .. winhl)
    for from, to in winhl:gmatch('([^,:]+):([^,]+)') do
      vim.api.nvim_set_hl(id, from, { link = to })
    end
    winhl_ns[winhl] = id
  end
  return winhl_ns[winhl]
end

--- The dim namespace: every highlight group defined now becomes the dimmed text colour, with
--- no background (so selections and the cursor line disappear too) — except the float's own
--- background and border.
function M.build()
  ns = ns or vim.api.nvim_create_namespace('perforated.stack.dim')
  local function get(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  local float, normal, comment = get('PerforatedFloat'), get('Normal'), get('Comment')
  local fg, bg = float.fg or normal.fg, float.bg or normal.bg
  local text, border
  if fg and bg then
    local hl = require('perforated.hl')
    local f, b = ('#%06x'):format(fg), ('#%06x'):format(bg)
    text, border = hl.blend(f, b, 0.55), hl.blend(f, b, 0.75) -- 55 % / 75 % of the way to bg
  else -- a theme without both colours: its comment colour reads as dimmed
    text = comment.fg
    border = text
  end
  local cterm = comment.ctermfg
  local plain = { fg = text, ctermfg = cterm }
  for name in pairs(vim.api.nvim_get_hl(0, {})) do
    vim.api.nvim_set_hl(ns, name, plain)
  end
  local base = { fg = text, bg = bg, ctermfg = cterm, ctermbg = float.ctermbg or normal.ctermbg }
  for _, name in ipairs({ 'Normal', 'NormalFloat', 'NormalNC', 'FloatTitle', 'FloatFooter' }) do
    vim.api.nvim_set_hl(ns, name, base)
  end
  vim.api.nvim_set_hl(
    ns,
    'FloatBorder',
    { fg = border, bg = bg, ctermfg = cterm, ctermbg = base.ctermbg }
  )
  built = true
end

---@param win integer
---@param e perforated.StackEntry
---@param state 'active'|'dim'|'plain'
local function apply(win, e, state)
  e.state = state
  if state == 'dim' then
    if not built then
      M.build()
    end
    vim.api.nvim_win_set_hl_ns(win, ns)
    e.dimmed = true
    return
  end
  local winhl = state == 'active' and e.active or e.base
  vim.wo[win][0].winhighlight = winhl
  if e.dimmed then
    vim.api.nvim_win_set_hl_ns(win, ns_of(winhl))
  end
end

--- Bring every registered pop-up up to date with the focus.
function M.update()
  local modal ---@type perforated.StackEntry?
  for win, e in pairs(entries) do
    if not vim.api.nvim_win_is_valid(win) then
      entries[win] = nil
    elseif e.modal and (not modal or e.seq > modal.seq) then
      modal = e
    end
  end
  local current = entries[vim.api.nvim_get_current_win()]
  local active = modal and modal.group or (current and current.group)
  for win, e in pairs(entries) do
    local state = active == nil and 'plain' or (e.group == active and 'active' or 'dim')
    if state ~= e.state then
      apply(win, e, state)
    end
  end
end

local did_autocmds = false
local function ensure_autocmds()
  if did_autocmds then
    return
  end
  did_autocmds = true
  local group = vim.api.nvim_create_augroup('perforated.stack', { clear = true })
  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = M.update })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev)
      if entries[tonumber(ev.match)] then
        vim.schedule(M.update) -- once the window is gone
      end
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      built = false
      for win, e in pairs(entries) do
        if e.state == 'dim' and vim.api.nvim_win_is_valid(win) then
          M.build()
          vim.api.nvim_win_set_hl_ns(win, ns)
        end
      end
    end,
  })
end

--- Take part in stacking. Call after setting the window's 'winhighlight'.
---@param win integer
---@param opts { modal: boolean?, group: any?, border: string? }?  group: windows that are one
---  pop-up; border: the group for its border while in use (default the accent,
---  `PerforatedFloatBorderActive`)
function M.register(win, opts)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  ensure_autocmds()
  require('perforated.hl').setup() -- PerforatedFloatBorderActive
  opts = opts or {}
  seq = seq + 1
  local base = vim.wo[win].winhighlight
  local border = 'FloatBorder:' .. (opts.border or 'PerforatedFloatBorderActive')
  local active, n = base:gsub('FloatBorder:[^,]*', border)
  if n == 0 then
    active = (base == '' and '' or (base .. ',')) .. border
  end
  entries[win] = {
    group = opts.group or win,
    modal = opts.modal,
    base = base,
    active = active,
    seq = seq,
  }
  M.update()
end

--- Stop taking part (a modal menu closing: the pop-up under it is active again at once).
---@param win integer
function M.unregister(win)
  entries[win] = nil
  M.update()
end

---@param win integer
---@return 'active'|'dim'|'plain'|nil
function M.state(win)
  return entries[win] and entries[win].state
end

return M
