--- Current-line blame: end-of-line virtual text with the changelist that last changed the
--- cursor's line. Opt-in (`blame_line = { enabled = true }` or `:P4 blame`).
---
--- The whole file is annotated once per `depotFile#rev` (history.annotate caches it); cursor
--- moves only read that result, after a `blame_line.delay` debounce. Lines changed locally
--- show "Not submitted".
---
--- One annotate at a time: asking for another revision (the cursor in another file) cancels
--- the one still running. A revision that failed isn't asked again for `M.FAIL_MS` (else each
--- cursor stop would start it again); `:P4 refresh` forgets the failures.

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.blame')
local group = nil ---@type integer?
local timer = nil ---@type uv.uv_timer_t?
M.enabled = nil ---@type boolean?  nil = follow config

--- How long (ms) a revision whose annotate failed isn't asked again.
M.FAIL_MS = 5 * 60 * 1000
local failed = {} ---@type table<string, integer>  workspace key + spec → when it failed
local current ---@type { key: string, req: { cancel: fun() } }?  the annotate running

--- Forget failed annotates (`:P4 refresh`, tests).
function M.forget()
  failed = {}
end

local function is_enabled()
  if M.enabled ~= nil then
    return M.enabled
  end
  return require('perforated.config').get().blame_line.enabled == true
end

local function clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

--- Format the text for a changelist's metadata.
---@param m table?
---@return string
function M.format(m)
  local fmt = require('perforated.config').get().blame_line.format
  m = m or {}
  local fields = {
    user = m.user or '?',
    date = require('perforated.views.base').date(m.time),
    desc = m.desc or '',
    change = tostring(m.change or ''),
    client = m.client or '',
  }
  return (fmt:gsub('{(%w+)}', function(k)
    return fields[k] or ''
  end))
end

--- The annotate spec for a buffer (nil: nothing submitted to blame).
---@param st perforated.BufState
---@return string?
local function spec_of(st)
  local rec = st.rec
  -- Binary files can't be annotated: skip them rather than retry on every cursor move.
  if not rec or not rec.depotFile or not require('perforated.p4').is_text(rec) then
    return nil
  end
  if rec.action then
    local s = require('perforated.p4').base_spec(rec)
    return s and s:match('#%d+$') and s or nil
  end
  return rec.haveRev and (rec.depotFile .. '#' .. rec.haveRev) or nil
end

--- Show the blame for the cursor line of the current window.
function M.update()
  local buf = vim.api.nvim_get_current_buf()
  local st = require('perforated.buffer').get(buf)
  if not st or not is_enabled() then
    return
  end
  local spec = spec_of(st)
  if not spec then
    return clear(buf)
  end
  local key = st.ws.key .. '\0' .. spec
  local at = failed[key]
  if at and vim.uv.now() - at < M.FAIL_MS then
    return clear(buf)
  end
  failed[key] = nil
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local prev = current
  local this = { key = key }
  current = this
  this.req = require('perforated.history').annotate(
    st.ws,
    spec,
    { descriptions = true },
    function(ann)
      if current == this then
        current = nil
      end
      if not ann then
        failed[key] = vim.uv.now()
        return
      end
      M._show(buf, lnum, st, ann)
    end
  )
  -- After asking: the same revision asked again keeps sharing its request.
  if prev and prev.req then
    prev.req.cancel()
  end
end

--- Show the blame of `lnum` from `ann`, if the cursor is still there.
function M._show(buf, lnum, st, ann)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Still on that line (a later move re-runs the update)?
  if vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_win_get_cursor(0)[1] ~= lnum then
    return
  end
  local b = require('perforated.views.base').base_line(st.hunks or {}, lnum)
  local text
  if not b then
    text = 'Not submitted'
  else
    local cl = ann.cls[b]
    if not cl then
      return clear(buf)
    end
    text = M.format(ann.meta[cl] or { change = cl })
  end
  clear(buf)
  vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
    virt_text = { { '    ' .. text, 'PerforatedBlame' } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

local function schedule_update()
  local delay = require('perforated.config').get().blame_line.delay or 150
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(delay, 0, vim.schedule_wrap(M.update))
end

--- Start following the cursor in Perforce buffers.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup('perforated.blame', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      if not require('perforated.buffer').get(ev.buf) then
        return
      end
      clear(ev.buf) -- the old text is wrong for the new line
      schedule_update()
    end,
  })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'BufLeave' }, {
    group = group,
    callback = function(ev)
      clear(ev.buf)
    end,
  })
end

--- Enable, disable or toggle.
---@param on boolean?  nil = toggle
function M.set(on)
  if on == nil then
    on = not is_enabled()
  end
  M.enabled = on
  if on then
    M.setup()
    M.update()
  else
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      group = nil
    end
    for buf in pairs(require('perforated.buffer').all()) do
      clear(buf)
    end
  end
  return on
end

return M
