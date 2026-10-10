--- Quickfix / location-list sink shared by every list-producing command.
---
--- * One `setqflist` call per list; `title` + `context = { perforated = true, kind }`.
--- * Entries carry `user_data = { depotFile, rev, change, action, kind }`.
--- * `quickfixtextfunc` aligns columns without enlarging stored entries.
--- * In a perforated list's window: `gr` re-runs the producer; `d` diff; `x` revert; `R`
---   resolve (entries that need it end with a dimmed "· R resolves").
--- * Lists of files to resolve stay current: after any change (`User PerforatedChanged`, e.g. a
---   resolve from the client view) their files are re-checked with one fstat per workspace
---   and entries that no longer need resolving are dropped; once the current list is empty,
---   its window closes.
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
    require('perforated.ui.toast').notify(('[perforated] %s: nothing to show'):format(spec.title))
  elseif open then
    if spec.loclist and spec.win and spec.win ~= 0 and vim.api.nvim_win_is_valid(spec.win) then
      vim.api.nvim_set_current_win(spec.win) -- :lopen opens the current window's list
    end
    vim.cmd(spec.loclist and 'lopen' or 'botright copen')
    -- FileType doesn't fire again when the window was already open: install keys directly.
    on_qf_buf(vim.api.nvim_get_current_buf())
  else
    require('perforated.ui.toast').notify(
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

M.RESOLVE_HINT = ' · R resolves'

--- quickfixtextfunc: `relative/path:lnum │ text`, headers verbatim; entries to resolve end with
--- the `R` hint.
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
      local ud = it.user_data
      out[#out + 1] = ('%s%s │ %s%s'):format(
        names[i],
        (' '):rep(math.max(width - vim.fn.strdisplaywidth(names[i]), 0)),
        it.text,
        type(ud) == 'table' and ud.kind == 'unresolved' and M.RESOLVE_HINT or ''
      )
    else
      out[#out + 1] = it.text
    end
  end
  return out
end

--- A function refreshing the list shown in the current quickfix/location window. The list is
--- captured now, so it still targets that list when called later (after an async op), even if
--- focus has moved. `quiet`: lists without a producer are left alone silently.
---@param quiet boolean?
---@return fun()
local function refresher(quiet)
  local win = vim.api.nvim_get_current_win()
  local wininfo = vim.fn.getwininfo(win)[1]
  local is_loc = wininfo and wininfo.loclist == 1
  local cur = is_loc and vim.fn.getloclist(win, { id = 0, title = 1 })
    or vim.fn.getqflist({ id = 0, title = 1 })
  return function()
    local producer = producers[cur.id]
    if not producer then
      if not quiet then
        require('perforated.ui.toast').notify('[perforated] this list cannot be refreshed')
      end
      return
    end
    producer(function(items)
      local w = { id = cur.id, items = items, title = cur.title }
      if is_loc then
        if vim.api.nvim_win_is_valid(win) then
          vim.fn.setloclist(win, {}, 'r', w)
        end
      else
        vim.fn.setqflist({}, 'r', w)
      end
    end)
  end
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
  map('gr', function()
    refresher()()
  end, 'perforated: refresh list')
  require('perforated.lookup').map(buf, nil)
  -- Opened-file lists: ● changed files stand out, unchanged ones (·) are dimmed.
  vim.api.nvim_buf_call(buf, function()
    local g = require('perforated.ui.icons').glyph('modified')
    vim.cmd(('syntax match PerforatedModified /│ \\zs%s/'):format(vim.fn.escape(g, '/\\*')))
    vim.cmd([[syntax match PerforatedUnchanged /^.*│ · .*$/]])
    vim.cmd(([[syntax match PerforatedDim /%s$/]]):format(M.RESOLVE_HINT))
  end)
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
      return require('perforated.ui.toast').notify('[perforated] no workspace file under cursor')
    end
    if
      require('perforated.ui.prompt').confirm(
        ('Revert %s?'):format(vim.fn.fnamemodify(path, ':~:.')),
        '&Revert\n&Cancel',
        2
      ) == 1
    then
      require('perforated.checkout').revert(ws, { path }, false, refresher(true))
    end
  end, 'perforated: revert entry')
  map('gm', function()
    local ws, path = entry_ws()
    if not ws then
      return require('perforated.ui.toast').notify('[perforated] no workspace file under cursor')
    end
    local refresh = refresher(true)
    require('perforated.checkout').pick_change(ws, function(cl)
      if cl then
        require('perforated.changelists').reopen(ws, { path }, cl, function()
          refresh()
        end)
      end
    end)
  end, 'perforated: move entry to changelist')
  map('R', function()
    local ws, path = entry_ws()
    if not ws then
      return require('perforated.ui.toast').notify('[perforated] no workspace file under cursor')
    end
    local refresh = refresher(true)
    require('perforated.resolve').run(ws, { path }, function()
      refresh()
    end)
  end, 'perforated: resolve entry')
  map('d', function()
    local it = entry_under_cursor()
    if it and it.valid == 1 and it.bufnr > 0 then
      vim.cmd('wincmd p')
      vim.cmd('buffer ' .. it.bufnr)
      require('perforated.commands').dispatch('diff', { fargs = {} })
    end
  end, 'perforated: diff entry')
end

-- List kinds whose `unresolved` entries are pruned once the file no longer needs resolving.
local RESOLVE_KINDS = { unresolved = true, sync_attention = true }

--- Re-check the files of every quickfix list of files to resolve (the whole quickfix history)
--- and drop entries that no longer need resolving (resolved elsewhere, reverted…). One fstat
--- per workspace and list; entries whose state is unknown are kept.
function M.prune_resolved()
  local p4 = require('perforated.p4')
  local last = vim.fn.getqflist({ nr = '$' }).nr
  for nr = 1, last do
    local l = vim.fn.getqflist({ nr = nr, id = 0, context = 1, items = 1 })
    local ctx = l.context
    if type(ctx) == 'table' and ctx.perforated and RESOLVE_KINDS[ctx.kind] then
      local by_ws = {} ---@type table<perforated.Workspace, string[]>
      local buf_of = {} ---@type table<string, integer>  path → the entry's buffer
      for _, it in ipairs(l.items) do
        local ud = it.user_data
        if type(ud) == 'table' and ud.kind == 'unresolved' and it.bufnr > 0 then
          local path = vim.api.nvim_buf_get_name(it.bufnr)
          local ws = require('perforated.core.activation').for_dir(vim.fs.dirname(path))
          if ws then
            by_ws[ws] = by_ws[ws] or {}
            table.insert(by_ws[ws], path)
            buf_of[path] = it.bufnr
          end
        end
      end
      for ws, paths in pairs(by_ws) do
        p4.fstat(ws, paths, { priority = 3 }, function(r)
          local done = {} -- bufnr → true: no longer needs resolving
          for _, path in ipairs(paths) do
            local rec = r.files[p4.key(ws, path)]
            if rec and not rec.unresolved then
              done[buf_of[path]] = true
            end
          end
          if next(done) == nil then
            return
          end
          -- Read the list again: it may have changed meanwhile (match entries by buffer).
          local cur = vim.fn.getqflist({ id = l.id, items = 1, title = 1 })
          if not cur.items then
            return -- the list is gone
          end
          local keep, left, entries = {}, 0, 0
          for _, it in ipairs(cur.items) do
            local ud = it.user_data
            local resolvable = type(ud) == 'table' and ud.kind == 'unresolved'
            if not (resolvable and done[it.bufnr]) then
              keep[#keep + 1] = it
              left = left + (resolvable and 1 or 0)
              entries = entries + (it.valid == 1 and 1 or 0)
            end
          end
          local title = cur.title
          if left == 0 and not title:find(' · all resolved$') then
            title = title .. ' · all resolved'
          end
          vim.fn.setqflist({}, 'r', { id = l.id, items = keep, title = title })
          -- Nothing left to look at: close the window if it's showing this list (an empty
          -- window would otherwise keep the focus and the space). Older lists stay in history.
          if entries == 0 and vim.fn.getqflist({ id = 0 }).id == l.id then
            vim.cmd('cclose')
          end
        end)
      end
    end
  end
end

local prune_timer ---@type uv.uv_timer_t?

local did_setup = false

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  -- 'quickfixtextfunc' can only name a function reachable from Vimscript (v:lua.<global>).
  -- selene: allow(global_usage)
  _G.PerforatedQfText = M.textfunc
  local group = vim.api.nvim_create_augroup('perforated.qf', { clear = true })
  -- Changes come in bursts (resolve, refresh, revert…): re-check once things settle.
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'PerforatedChanged',
    callback = function()
      prune_timer = prune_timer or vim.uv.new_timer()
      prune_timer:stop()
      prune_timer:start(300, 0, vim.schedule_wrap(M.prune_resolved))
    end,
  })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
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
