--- Quickfix / location-list sink shared by every list-producing command.
---
--- * One `setqflist` call per list; `title` + `context = { perforated = true, kind }`.
--- * Entries carry `user_data = { depotFile, rev, change, action, kind }`.
--- * `quickfixtextfunc` aligns columns without enlarging stored entries.
--- * In a perforated list's window: `gr` re-runs the producer; `d` diff; `x` revert.
--- * Opening policy: open when non-empty and `qf.open` (default); otherwise a count is shown.

local M = {}

local producers = {} ---@type table<integer, fun(cb: fun(items: table[]))>  list id → producer
local on_qf_buf -- forward declaration

---@class perforated.QfSpec
---@field title string
---@field kind string
---@field items table[]
---@field loclist boolean?
---@field win integer?         loclist window (default current)
---@field open boolean?        override config.qf.open
---@field producer fun(cb: fun(items: table[]))?  for `gr` refresh

local function what(spec, items)
  return {
    title = spec.title,
    items = items,
    context = { perforated = true, kind = spec.kind },
    quickfixtextfunc = 'v:lua.PerforatedQfText',
  }
end

--- Create a list (and open it per policy).
---@param spec perforated.QfSpec
---@return integer id
function M.set(spec)
  M.setup()
  local w = what(spec, spec.items)
  local id
  if spec.loclist then
    local win = spec.win or 0
    vim.fn.setloclist(win, {}, ' ', w)
    id = vim.fn.getloclist(win, { id = 0 }).id
  else
    vim.fn.setqflist({}, ' ', w)
    id = vim.fn.getqflist({ id = 0 }).id
  end
  producers[id] = spec.producer
  local open = spec.open
  if open == nil then
    open = require('perforated.config').get().qf.open
  end
  local n = 0
  for _, it in ipairs(spec.items) do
    if it.valid ~= 0 then
      n = n + 1
    end
  end
  if n == 0 then
    vim.notify(('[perforated] %s: nothing to show'):format(spec.title))
  elseif open then
    vim.cmd(spec.loclist and 'lopen' or 'botright copen')
    -- FileType doesn't fire again when the window was already open: install keys directly.
    on_qf_buf(vim.api.nvim_get_current_buf())
  else
    vim.notify(
      ('[perforated] %s: %d entries in %s'):format(
        spec.title,
        n,
        spec.loclist and 'location list' or 'quickfix'
      )
    )
  end
  return id
end

--- File entry helper.
---@param path string
---@param text string
---@param data table?
---@param lnum integer?
function M.item(path, text, data, lnum)
  return { filename = path, lnum = lnum or 1, col = 1, text = text, user_data = data }
end

--- Non-jumpable group header.
---@param text string
function M.header(text)
  return { text = text, valid = 0, user_data = { kind = 'header' } }
end

--- quickfixtextfunc: `relative/path:lnum │ text`, headers verbatim.
function M.textfunc(info)
  local list = info.quickfix == 1 and vim.fn.getqflist({ id = info.id, items = 1 }).items
    or vim.fn.getloclist(info.winid, { id = info.id, items = 1 }).items
  local out = {}
  local width = 0
  local names = {}
  for i = info.start_idx, info.end_idx do
    local it = list[i]
    if it.valid == 1 and it.bufnr > 0 then
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ':~:.')
      if it.lnum > 1 then
        name = name .. ':' .. it.lnum
      end
      names[i] = name
      width = math.max(width, vim.fn.strdisplaywidth(name))
    end
  end
  width = math.min(width, 60)
  for i = info.start_idx, info.end_idx do
    local it = list[i]
    if names[i] then
      out[#out + 1] = ('%s%s │ %s'):format(
        names[i],
        (' '):rep(math.max(width - vim.fn.strdisplaywidth(names[i]), 0)),
        it.text
      )
    else
      out[#out + 1] = it.text
    end
  end
  return out
end

--- Refresh the list shown in the current quickfix/location window.
local function refresh_current()
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local is_loc = wininfo and wininfo.loclist == 1
  local get = is_loc and function(w)
    return vim.fn.getloclist(0, w)
  end or vim.fn.getqflist
  local cur = get({ id = 0, title = 1 })
  local producer = producers[cur.id]
  if not producer then
    return vim.notify('[perforated] this list cannot be refreshed')
  end
  producer(function(items)
    local w = { id = cur.id, items = items, title = cur.title }
    if is_loc then
      vim.fn.setloclist(0, {}, 'r', w)
    else
      vim.fn.setqflist({}, 'r', w)
    end
  end)
end

local function entry_under_cursor()
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local idx = vim.fn.line('.')
  local items = wininfo.loclist == 1 and vim.fn.getloclist(0) or vim.fn.getqflist()
  return items[idx]
end

--- Buffer-local keys in a perforated quickfix window.
---@param buf integer
on_qf_buf = function(buf)
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  if not wininfo then
    return
  end
  local ctx = wininfo.loclist == 1 and vim.fn.getloclist(0, { context = 1 }).context
    or vim.fn.getqflist({ context = 1 }).context
  if type(ctx) ~= 'table' or not ctx.perforated then
    return
  end
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map('gr', refresh_current, 'perforated: refresh list')
  local function entry_ws()
    local it = entry_under_cursor()
    if not it or it.valid ~= 1 or it.bufnr == 0 then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(it.bufnr)
    if path:match('^perforated://') then
      return nil
    end
    local wsmod = require('perforated.core.workspace')
    local ws = wsmod.for_buf(it.bufnr)
      or require('perforated.core.activation').for_dir(vim.fs.dirname(path))
    return ws, path, it
  end
  map('x', function()
    local ws, path = entry_ws()
    if not ws then
      return vim.notify('[perforated] no workspace file under cursor')
    end
    if
      vim.fn.confirm(('Revert %s?'):format(vim.fn.fnamemodify(path, ':~:.')), '&Revert\n&Cancel', 2)
      == 1
    then
      require('perforated.checkout').revert(ws, { path }, false, refresh_current)
    end
  end, 'perforated: revert entry')
  map('M', function()
    local ws, path = entry_ws()
    if not ws then
      return vim.notify('[perforated] no workspace file under cursor')
    end
    require('perforated.checkout').pick_change(ws, function(cl)
      if cl then
        require('perforated.changelists').reopen(ws, { path }, cl, function()
          refresh_current()
        end)
      end
    end)
  end, 'perforated: move entry to changelist')
  map('d', function()
    local it = entry_under_cursor()
    if it and it.valid == 1 and it.bufnr > 0 then
      vim.cmd('wincmd p')
      vim.cmd('buffer ' .. it.bufnr)
      require('perforated.commands').dispatch('diff', { fargs = {} })
    end
  end, 'perforated: diff entry')
end

local did_setup = false

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  -- 'quickfixtextfunc' can only name a function reachable from Vimscript (v:lua.<global>).
  -- selene: allow(global_usage)
  _G.PerforatedQfText = M.textfunc
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('perforated.qf', { clear = true }),
    pattern = 'qf',
    callback = function(ev)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_get_current_buf() == ev.buf then
          on_qf_buf(ev.buf)
        end
      end)
    end,
  })
end

return M
