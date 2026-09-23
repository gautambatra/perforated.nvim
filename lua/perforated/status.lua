--- Statusline data. Statuslines only read variables; they never call into p4.
---
---   vim.b.perforated_status_dict  per buffer: { status, action, change, have, head, stale,
---                                  unresolved, added, changed, removed, conn, ws }
---   vim.b.perforated_status       per buffer: ready-made string
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

---@param buf integer
function M.update(buf)
  local st = require('perforated.buffer').get(buf)
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = require('perforated.config').get().statusline
  local icons = require('perforated.ui.icons')
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
  local parts = {}
  if st.status == 'opened' or st.status == 'binary' then
    parts[#parts + 1] =
      vim.trim(icons.action(rec.action) .. ' ' .. rec.action .. '@' .. (rec.change or 'default'))
    if sum.added > 0 then
      parts[#parts + 1] = '+' .. sum.added
    end
    if sum.changed > 0 then
      parts[#parts + 1] = '~' .. sum.changed
    end
    if sum.removed > 0 then
      parts[#parts + 1] = '-' .. sum.removed
    end
  elseif st.status == 'clean' and rec.haveRev then
    parts[#parts + 1] = '#' .. rec.haveRev
  elseif st.status == 'new' then
    parts[#parts + 1] = 'not in depot'
  end
  if stale then
    parts[#parts + 1] = ('%s#%s→#%s'):format(cfg.stale, rec.haveRev, rec.headRev)
  end
  if unresolved then
    parts[#parts + 1] = cfg.unresolved .. 'unresolved'
  end
  vim.b[buf].perforated_status_dict = d
  vim.b[buf].perforated_status = table.concat(parts, ' ')
  require('perforated.signs').render_stale(buf, stale)
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
---   e.g. " edit@123 +3 ~1 ↓#4→#5   ↓2 !1"
---@return string
function M.statusline()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.b[buf].perforated_status
  local g = vim.g.perforated_status
  if not file and not g then
    return ''
  end
  local cfg = require('perforated.config').get().statusline
  local parts = { file }
  if g and vim.b[buf].perforated_ws == g.ws then
    local wsp = {}
    if (g.stale or 0) > 0 then
      wsp[#wsp + 1] = cfg.stale .. g.stale
    end
    if (g.unresolved or 0) > 0 then
      wsp[#wsp + 1] = cfg.unresolved .. g.unresolved
    end
    if g.conn == 'offline' or g.conn == 'offline_auth' then
      wsp[#wsp + 1] = cfg.offline
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
