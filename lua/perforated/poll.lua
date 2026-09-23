--- Stale / unresolved detection.
---
--- Perforce can't push notifications, so we poll cheaply:
---   probe = `changes -m1 -s submitted <opened + loaded files>` (one indexed query); only when
---   it reports a newer change than last time do we run the full `fstat -Ro //client/...`.
--- Triggers: workspace activation (idle), a timer while focused (poll.interval, 0 = off),
--- FocusGained (throttled) and BufEnter of a p4 buffer (per-buffer fstat, throttled).
--- Newly stale opened files raise a toast (once per head revision).

local p4 = require('perforated.p4')
local dbg = require('perforated.core.debug')

local M = {}

local timer ---@type uv.uv_timer_t?
local started = {} ---@type table<string, boolean>
local last_focus_probe = 0
local last_enter = {} ---@type table<integer, integer>

local function cfg()
  return require('perforated.config').get().poll
end

---@param ws perforated.Workspace
---@return string[]
local function watched_files(ws)
  local files, seen = {}, {}
  for depot in pairs(ws.opened or {}) do
    seen[depot] = true
    files[#files + 1] = depot
  end
  for _, st in pairs(require('perforated.buffer').all()) do
    if st.ws == ws and st.rec and st.rec.depotFile and not seen[st.rec.depotFile] then
      seen[st.rec.depotFile] = true
      files[#files + 1] = st.rec.depotFile
    end
  end
  table.sort(files)
  return files
end

--- Fill in user/description for changes we don't know yet (one describe call).
---@param ws perforated.Workspace
---@param changes string[]
---@param cb fun()
local function learn_changes(ws, changes, cb)
  local need = {}
  for _, c in ipairs(changes) do
    if not ws.clmemo[c] then
      need[#need + 1] = c
    end
  end
  if #need == 0 then
    return cb()
  end
  ws:run(vim.list_extend({ 'describe', '-s' }, need), { priority = 3 }, function(res)
    for _, r in ipairs(res.records) do
      if r.change then
        ws.clmemo[r.change] = { user = r.user, client = r.client, time = r.time, desc = r.desc }
      end
    end
    cb()
  end)
end

---@param ws perforated.Workspace
---@param recs table[]
---@param initial boolean
local function toast_for(ws, recs, initial)
  local icons = require('perforated.ui.icons')
  local changes = {}
  for _, r in ipairs(recs) do
    if r.headChange then
      changes[#changes + 1] = r.headChange
    end
  end
  learn_changes(ws, changes, function()
    local lines = {}
    local nstale, nunres = 0, 0
    for _, r in ipairs(recs) do
      local name = vim.fn.fnamemodify(r.clientFile or r.depotFile, ':~:.')
      if require('perforated.status').is_stale(r) then
        nstale = nstale + 1
        local m = ws.clmemo[r.headChange or ''] or {}
        lines[#lines + 1] = ('%s %s  #%s→#%s · CL %s%s'):format(
          icons.glyph('stale'),
          name,
          r.haveRev,
          r.headRev,
          r.headChange or '?',
          m.user and (' · ' .. m.user) or ''
        )
      end
      if r.unresolved then
        nunres = nunres + 1
        lines[#lines + 1] = ('%s %s  unresolved'):format(icons.glyph('unresolved'), name)
      end
    end
    if #lines == 0 then
      return
    end
    lines[#lines + 1] = 'sync before submitting · :P4 status for details'
    local title
    if initial then
      title = ('Perforce: %d stale, %d unresolved opened file(s)'):format(nstale, nunres)
    else
      title = ('Perforce: %d opened file(s) now stale'):format(nstale)
    end
    require('perforated.ui.toast').show(title, lines, vim.log.levels.WARN)
  end)
end

--- Full refresh of opened-file state (one `fstat -Ro`), updating counts, buffers and toasts.
---@param ws perforated.Workspace
---@param opts { initial: boolean?, notify: boolean? }?
---@param cb fun()?
function M.refresh(ws, opts, cb)
  opts = opts or {}
  p4.fstat_opened(ws, { priority = 3 }, function(recs)
    if not recs then
      return cb and cb()
    end
    local opened, stale, unres = {}, 0, 0
    ws.stale_seen = ws.stale_seen or {}
    local fresh = {}
    for _, r in ipairs(recs) do
      opened[r.depotFile] = r
      local is_stale = require('perforated.status').is_stale(r)
      if is_stale then
        stale = stale + 1
        local mark = r.depotFile .. '#' .. r.headRev
        if not ws.stale_seen[mark] then
          ws.stale_seen[mark] = true
          fresh[#fresh + 1] = r
        end
      end
      if r.unresolved then
        unres = unres + 1
        if opts.initial then
          fresh[#fresh + 1] = not is_stale and r or nil
        end
      end
      if r.clientFile then
        ws.fstat[p4.key(ws, r.clientFile)] = r
      end
    end
    ws.opened = opened
    ws.opened_count, ws.stale_count, ws.unresolved_count = #recs, stale, unres
    dbg.info(
      'poll',
      '%s refresh: opened=%d stale=%d unresolved=%d newly-reported=%d',
      ws.key,
      #recs,
      stale,
      unres,
      #fresh
    )
    -- Push fresh records into loaded buffers (cheap: no base refetch unless the have rev moved).
    for buf, st in pairs(require('perforated.buffer').all()) do
      if st.ws == ws and st.rec and opened[st.rec.depotFile] then
        local r = opened[st.rec.depotFile]
        if r.haveRev ~= st.rec.haveRev or r.action ~= st.rec.action then
          require('perforated.buffer').apply(buf, r)
        else
          st.rec = r
          require('perforated.status').update(buf)
        end
      end
    end
    require('perforated.status').update_ws(ws)
    if opts.notify ~= false and #fresh > 0 then
      toast_for(ws, fresh, opts.initial)
    end
    if cb then
      cb()
    end
  end)
end

--- Cheap probe; escalates to a full refresh (plus loaded clean buffers) only on news.
---@param ws perforated.Workspace
function M.probe(ws)
  if ws.idle or ws.conn.state ~= 'online' or not require('perforated.ui.toast').focused then
    dbg.trace(
      'poll',
      '%s probe skipped (idle=%s conn=%s focused=%s)',
      ws.key,
      tostring(ws.idle),
      ws.conn.state,
      tostring(require('perforated.ui.toast').focused)
    )
    return
  end
  local files = watched_files(ws)
  if #files == 0 then
    return
  end
  p4.latest_changes(ws, files, function(max, by)
    if not max then
      return
    end
    for c, r in pairs(by) do
      ws.clmemo[c] = ws.clmemo[c]
        or { user = r.user, client = r.client, time = r.time, desc = r.desc }
    end
    dbg.debug(
      'poll',
      '%s probe: %d file(s) newest change=%s last=%s',
      ws.key,
      #files,
      tostring(max),
      tostring(ws.last_max)
    )
    if ws.last_max and max <= ws.last_max then
      return
    end
    local first = ws.last_max == nil
    ws.last_max = max
    if first then
      return -- baseline; activation already did a full refresh
    end
    M.refresh(ws)
    for buf, st in pairs(require('perforated.buffer').all()) do
      if st.ws == ws and st.status == 'clean' then
        require('perforated.buffer').refresh(buf)
      end
    end
  end)
end

local function probe_all()
  for _, ws in ipairs(require('perforated.core.workspace').list()) do
    M.probe(ws)
  end
end

local function ensure_timer()
  local interval = cfg().interval
  if timer or not interval or interval <= 0 then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(interval * 1000, interval * 1000, function()
    vim.schedule(probe_all)
  end)
end

local did_autocmds = false
local function ensure_autocmds()
  if did_autocmds then
    return
  end
  did_autocmds = true
  local group = vim.api.nvim_create_augroup('perforated.poll', { clear = true })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      local now = vim.uv.now()
      if now - last_focus_probe >= cfg().focus_throttle * 1000 then
        last_focus_probe = now
        vim.schedule(probe_all)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if not require('perforated.buffer').get(ev.buf) then
        return
      end
      local now = vim.uv.now()
      if now - (last_enter[ev.buf] or -math.huge) >= cfg().bufenter_throttle * 1000 then
        last_enter[ev.buf] = now
        require('perforated.buffer').refresh(ev.buf)
      end
    end,
  })
end

--- Start watching a workspace (idempotent). The first full check runs when idle.
---@param ws perforated.Workspace
function M.start(ws)
  if started[ws.key] then
    return
  end
  started[ws.key] = true
  ensure_autocmds()
  ensure_timer()
  if require('perforated.config').get().startup_check then
    vim.defer_fn(function()
      ws:ensure_info(function()
        M.refresh(ws, { initial = true }, function()
          M.probe(ws) -- establish the baseline
        end)
      end, 3)
    end, 200)
  end
end

function M._reset()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  started, last_enter, last_focus_probe = {}, {}, 0
end

return M
