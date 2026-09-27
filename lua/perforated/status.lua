--- Statusline data. Statuslines only read variables; they never call into p4.
---
---   vim.b.perforated_status_dict  per buffer: { status, action, change, have, head, stale,
---                                  unresolved, added, changed, removed, modified, client,
---                                  conn, ws }
---   vim.b.perforated_status       per buffer: ready-made string (`statusline.format`)
---   vim.g.perforated_status       workspace of the current buffer: { ws, client, user, conn,
---                                  opened, stale, unresolved }
---
--- Every change fires `User PerforatedStatus` (coalesced) and redraws statuslines.

local M = {}

local pending = false

local function notify_changed()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    require('perforated.core.events').emit('Status')
    pcall(vim.cmd.redrawstatus)
    -- lualine caches its render between refresh ticks (up to 1 s): nudge it when loaded.
    local lualine = package.loaded['lualine']
    if lualine and lualine.refresh then
      pcall(lualine.refresh, { place = { 'statusline' } })
    end
  end)
end

---@param rec table?
---@return boolean
local function is_stale(rec)
  if not rec then
    return false
  end
  local have, head = tonumber(rec.haveRev), tonumber(rec.headRev)
  return have ~= nil and head ~= nil and have < head
end
M.is_stale = is_stale

--- Workspace-level summary.
---@param ws perforated.Workspace
---@return table
function M.ws_summary(ws)
  return {
    ws = ws.key,
    client = ws:client(),
    user = ws:user(),
    conn = ws.conn.state,
    opened = ws.opened_count or 0,
    stale = ws.stale_count or 0,
    unresolved = ws.unresolved_count or 0,
  }
end

--- The pieces a statusline format can use (empty when they don't apply).
---@param d table  the status dict (vim.b.perforated_status_dict)
---@param cfg table  config.statusline
---@return table<string, string>
function M.tokens(d, cfg)
  local icons = require('perforated.ui.icons')
  local opened = d.status == 'opened' or d.status == 'binary'
  local t = { client = d.client or '' }
  t.action = opened
      and vim.trim(icons.action(d.action) .. ' ' .. d.action .. '@' .. (d.change or 'default'))
    or ''
  t.change = opened and (d.change or 'default') or ''
  t.modified = d.modified and icons.glyph('modified') or ''
  if d.have then
    t.rev = '#' .. d.have
  elseif d.status == 'new' then
    t.rev = 'not in depot'
  else
    t.rev = ''
  end
  t.head = d.head and ('#' .. d.head) or ''
  t.stale = d.stale and (cfg.stale .. '#' .. d.head) or ''
  t.unresolved = d.unresolved and (cfg.unresolved .. 'unresolved') or ''
  local diff = {}
  if (d.added or 0) > 0 then
    diff[#diff + 1] = '+' .. d.added
  end
  if (d.changed or 0) > 0 then
    diff[#diff + 1] = '~' .. d.changed
  end
  if (d.removed or 0) > 0 then
    diff[#diff + 1] = '-' .. d.removed
  end
  t.diff = table.concat(diff, ' ')
  return t
end

--- The file part of the statusline: `statusline.format` (a template or a function of the
--- status dict). Tokens that don't apply vanish along with the extra spaces.
---@param d table
---@param cfg table
---@return string
function M.format(d, cfg)
  local fmt = cfg.format
  if type(fmt) == 'function' then
    local ok, out = pcall(fmt, d)
    return ok and tostring(out or '') or ''
  end
  if d.status == 'pending' or d.status == 'unmanaged' then
    return ''
  end
  local t = M.tokens(d, cfg)
  local out = (fmt or ''):gsub('{(%w+)}', function(k)
    return t[k] or ''
  end)
  return vim.trim((out:gsub('  +', ' ')))
end

---@param buf integer
function M.update(buf)
  local st = require('perforated.buffer').get(buf)
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = require('perforated.config').get().statusline
  local rec = st.rec or {}
  local sum = require('perforated.diff.engine').summary(st.hunks or {})
  local stale = is_stale(st.rec)
  local unresolved = rec.unresolved ~= nil
  local d = {
    status = st.status,
    action = rec.action,
    change = rec.change,
    have = rec.haveRev,
    head = rec.headRev,
    stale = stale,
    unresolved = unresolved,
    added = sum.added,
    changed = sum.changed,
    removed = sum.removed,
    conn = st.ws.conn.state,
    ws = st.ws.key,
  }
  d.client = st.ws:client()
  d.modified = #(st.hunks or {}) > 0
  local line = M.format(d, cfg)
  -- Runs after every re-diff while typing: skip the Vimscript conversions, the extmark and the
  -- redraw when nothing the statusline shows has changed.
  local sig = table.concat({
    line,
    tostring(d.client),
    tostring(d.modified),
    st.status,
    tostring(rec.action),
    tostring(rec.change),
    tostring(rec.haveRev),
    tostring(rec.headRev),
    tostring(stale),
    tostring(unresolved),
    sum.added,
    sum.changed,
    sum.removed,
    d.conn,
    d.ws,
  }, '\0')
  local signs = require('perforated.signs')
  if
    st.status_sig == sig
    and vim.b[buf].perforated_status == line
    and stale == (#vim.api.nvim_buf_get_extmarks(buf, signs.ns_stale, 0, -1, { limit = 1 }) > 0)
  then
    return
  end
  st.status_sig = sig
  vim.b[buf].perforated_status_dict = d
  vim.b[buf].perforated_status = line
  signs.render_stale(buf, stale)
  if buf == vim.api.nvim_get_current_buf() then
    vim.g.perforated_status = M.ws_summary(st.ws)
  end
  notify_changed()
end

--- Workspace counts changed (poller): refresh the global summary.
---@param ws perforated.Workspace
function M.update_ws(ws)
  local cur = require('perforated.buffer').get(vim.api.nvim_get_current_buf())
  if cur and cur.ws == ws then
    vim.g.perforated_status = M.ws_summary(ws)
  end
  notify_changed()
end

---@param buf integer
function M.on_enter(buf)
  local st = require('perforated.buffer').get(buf)
  if st then
    vim.g.perforated_status = M.ws_summary(st.ws)
    notify_changed()
  end
end

--- Ready-made statusline component for the current buffer: file state + workspace markers.
---   e.g. "alice_ws edit@123 ● #4 ↓#5  ↓2 !1"
---@return string
function M.statusline()
  local buf = vim.api.nvim_get_current_buf()
  -- Evaluated on every redraw: bail out before touching vim.g for non-Perforce buffers.
  local ws = vim.b[buf].perforated_ws
  if not ws then
    return ''
  end
  local file = vim.b[buf].perforated_status
  local g = vim.g.perforated_status
  if not file and not g then
    return ''
  end
  local cfg = require('perforated.config').get().statusline
  local parts = { file }
  if g and ws == g.ws then
    local wsp = {}
    if (g.stale or 0) > 0 then
      wsp[#wsp + 1] = cfg.stale .. g.stale
    end
    if (g.unresolved or 0) > 0 then
      wsp[#wsp + 1] = cfg.unresolved .. g.unresolved
    end
    if g.conn == 'offline' then
      wsp[#wsp + 1] = cfg.offline
    elseif g.conn == 'offline_auth' then
      wsp[#wsp + 1] = cfg.offline .. 'login'
    end
    if #wsp > 0 then
      parts[#parts + 1] = table.concat(wsp, ' ')
    end
  end
  return vim.trim(table.concat(
    vim.tbl_filter(function(p)
      return p and p ~= ''
    end, parts),
    '  '
  ))
end

return M
