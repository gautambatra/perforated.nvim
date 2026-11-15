--- Stale / unresolved detection.
---
--- Perforce can't push notifications, so we poll cheaply. A probe is two small queries:
---   * `changes -m1 -s submitted <opened + loaded files>` (one indexed query): someone submitted
---     a newer revision of a file we care about;
---   * `opened` (this client's opened-file records): files were opened, reverted, moved or
---     unshelved from elsewhere (another terminal, P4V), which no submit would reveal;
---   * `changes -s pending -l -c <client>` (this client's pending changelists): a changelist
---     created, deleted, described or shelved elsewhere, with the opened files unchanged.
--- A newer submit or different opened files run the full `fstat -Ro //client/...`; different
--- pending changelists only announce a change (a visible client view refreshes).
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

--- Refresh of opened-file state, updating counts, buffers and toasts: one `fstat -Ro` of
--- every opened file, or with `opts.files` (and opened files known) one `fstat` of those.
---@param ws perforated.Workspace
---@param opts { initial: boolean?, notify: boolean?, timeout: integer?, files: string[]? }?  timeout: ms (default: background)
---@param cb fun(recs: table[]?, res: perforated.RunResult)?  the opened records (nil: failed)
function M.refresh(ws, opts, cb)
  opts = opts or {}
  -- Following the plugin's changes (loaded with the first one): a change since the last
  -- refresh explains what this one finds, its listeners already heard of it, so no `poll`
  -- news (one more view refresh) for it.
  local follow = package.loaded['perforated.poll_follow']
  local explained = follow and follow.begin(ws)
  local function finish(recs, res)
    if follow then
      follow.finish(ws, recs, res)
    end
    if cb then
      cb(recs, res)
    end
  end
  local function fetch(got)
    if opts.files and ws.opened then
      return require('perforated.poll_follow').opened_with(ws, opts.files, opts, got)
    end
    p4.fstat_opened(ws, { priority = 3, timeout = opts.timeout }, got)
  end
  local asked, stamp = vim.uv.hrtime(), p4.stamp(ws)
  fetch(function(recs, res, named)
    if not recs then
      return finish(nil, res)
    end
    if (ws.opened_at or 0) > asked then
      -- A refresh asked later has answered already (the quick one after a change that came
      -- while this one ran): this older answer mustn't undo it.
      dbg.debug('poll', '%s refresh: answer older than the one applied, dropped', ws.key)
      local now = vim.tbl_values(ws.opened)
      table.sort(now, function(a, b)
        return a.depotFile < b.depotFile
      end)
      return finish(now, res)
    end
    ws.opened_at = asked
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
        local k = p4.key(ws, r.clientFile)
        -- (a merged answer: only the files it asked about are this fresh)
        if not named or named[k] then
          ws.fstat[k], ws.fstat_at[k] = r, stamp
        end
      end
    end
    ws.opened = opened
    if not named then
      ws.opened_stamp = stamp
    end
    -- Files no longer opened (reverted, submitted) mustn't keep an "opened" cache entry.
    for k, rec in pairs(ws.fstat) do
      if rec.action and not opened[rec.depotFile] then
        ws.fstat[k], ws.fstat_at[k] = nil, nil
      end
    end
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
    local shown, by_key = {}, {}
    for _, r in ipairs(recs) do
      if r.clientFile then
        by_key[p4.key(ws, r.clientFile)] = r
      end
    end
    for buf, st in pairs(require('perforated.buffer').all()) do
      local n = named and st.ws == ws and named[st.key]
      if n then
        shown[st.key] = true
        local r = n.rec
        if not (r and st.rec) or r.haveRev ~= st.rec.haveRev or r.action ~= st.rec.action then
          require('perforated.buffer').apply(buf, r, n.missing)
        else
          st.rec = r
          require('perforated.status').update(buf)
        end
      elseif st.ws == ws and (st.rec and opened[st.rec.depotFile] or by_key[st.key]) then
        -- (by its path: a file just added has no record yet)
        local r = st.rec and opened[st.rec.depotFile] or by_key[st.key]
        if not st.rec or r.haveRev ~= st.rec.haveRev or r.action ~= st.rec.action then
          require('perforated.buffer').apply(buf, r)
        else
          st.rec = r
          require('perforated.status').update(buf)
        end
      elseif st.ws == ws and st.rec and st.rec.action then
        require('perforated.buffer').refresh(buf) -- no longer opened (reverted, submitted)
      end
    end
    -- A named file that isn't opened: its record is kept while a buffer shows it.
    for k, n in pairs(named or {}) do
      if n.rec and not n.rec.action then
        ws.fstat[k] = shown[k] and n.rec or nil
        ws.fstat_at[k] = shown[k] and stamp or nil
      end
    end
    require('perforated.status').update_ws(ws)
    if opts.notify ~= false and #fresh > 0 then
      require('perforated.stale_toast').show(ws, fresh, opts.initial)
    end
    -- News for views and lists (a visible client view refreshes, resolve lists re-check): only
    -- when the opened files' state really differs from the last refresh, never on the first.
    local sig = {}
    for _, r in ipairs(recs) do
      sig[#sig + 1] = table.concat({
        r.depotFile,
        r.haveRev or '',
        r.headRev or '',
        r.action or '',
        r.change or '',
        r.unresolved and 'u' or '',
      }, '|')
    end
    table.sort(sig)
    local key = table.concat(sig, '\n')
    if ws.poll_sig and ws.poll_sig ~= key and not explained then
      require('perforated.core.events').emit('Changed', { ws = ws.key, source = 'poll' })
    end
    ws.poll_sig = key
    finish(recs, res)
  end)
end

--- The opened files once the plugin's changes so far are answered (see `poll_follow`).
---@param ws perforated.Workspace
---@param cb fun(recs: table[]?, res: perforated.RunResult?)
function M.settled(ws, cb)
  return require('perforated.poll_follow').settled(ws, cb)
end

--- Whether this workspace's changes are followed (`settled` answers after them).
---@param ws perforated.Workspace
---@return boolean
function M.following(ws)
  return started[ws.key] == true
end

--- Cheap probe; escalates to a full refresh (plus loaded clean buffers) only on news.
---@param ws perforated.Workspace
function M.probe(ws)
  if ws.idle or ws.conn.state ~= 'online' or not M.focused then
    dbg.trace(
      'poll',
      '%s probe skipped (idle=%s conn=%s focused=%s)',
      ws.key,
      tostring(ws.idle),
      ws.conn.state,
      tostring(M.focused)
    )
    return
  end
  -- Opened files changed elsewhere (unshelve, edit, revert, reopen from another terminal)?
  -- Compared with the last full refresh; works with nothing opened yet, too.
  if ws.opened then
    ws:run({ 'opened' }, { priority = 3, key = 'probe-opened:' .. ws.key }, function(res)
      if #res.errors > 0 and #res.records == 0 then
        return -- ("file(s) not opened" is a warning: an empty client is a valid answer)
      end
      local now, before = {}, {}
      for _, r in ipairs(res.records) do
        if r.depotFile then
          now[#now + 1] = r.depotFile .. '|' .. (r.action or '') .. '|' .. (r.change or '')
        end
      end
      for depot, r in pairs(ws.opened or {}) do
        before[#before + 1] = depot .. '|' .. (r.action or '') .. '|' .. (r.change or '')
      end
      table.sort(now)
      table.sort(before)
      if table.concat(now, '\n') ~= table.concat(before, '\n') then
        dbg.debug('poll', '%s probe: opened files changed elsewhere', ws.key)
        p4.opened_changed(ws)
        M.refresh(ws)
      end
    end)
  end
  -- Pending changelists changed elsewhere (new, deleted, description, shelf)?
  local client = ws:client()
  if client then
    local stamp = p4.stamp(ws)
    ws:run(
      { 'changes', '-s', 'pending', '-l', '-c', client },
      { priority = 3, key = 'probe-pending:' .. ws.key },
      function(res)
        if not res.ok then
          return
        end
        p4.keep_pending(ws, stamp, res.records) -- pickers and prompts may reuse it
        local sig = {}
        for _, r in ipairs(res.records) do
          if r.change then
            sig[#sig + 1] = table.concat({ r.change, r.desc or '', r.shelved and 's' or '' }, '|')
          end
        end
        table.sort(sig)
        local key = table.concat(sig, '\n')
        if ws.pending_sig and ws.pending_sig ~= key then
          dbg.debug('poll', '%s probe: pending changelists changed elsewhere', ws.key)
          require('perforated.core.events').emit('Changed', { ws = ws.key, source = 'poll' })
        end
        ws.pending_sig = key
      end
    )
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
    p4.opened_changed(ws)
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

--- Whether Neovim has focus: polling runs only while it does. Tracked here from the first
--- workspace on (the toast module tracks it only once a toast has been shown).
M.focused = true

local did_autocmds = false
local function ensure_autocmds()
  if did_autocmds then
    return
  end
  did_autocmds = true
  local group = vim.api.nvim_create_augroup('perforated.poll', { clear = true })
  vim.api.nvim_create_autocmd('FocusLost', {
    group = group,
    callback = function()
      M.focused = false
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M.focused = true
      -- The timer skipped every tick while unfocused, so each return must catch up: the
      -- throttle (2 s by default) only absorbs focus flapping (tmux pane switches).
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
      local st = require('perforated.buffer').get(ev.buf)
      if not st or p4.fresh(st.ws, st.ws.fstat_at[st.key]) then
        return -- (its record was fetched moments ago)
      end
      local now = vim.uv.now()
      if now - (last_enter[ev.buf] or -math.huge) >= cfg().bufenter_throttle * 1000 then
        last_enter[ev.buf] = now
        require('perforated.buffer').refresh(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'PerforatedChanged',
    callback = function(ev)
      local d = ev.data or {}
      -- `poll` and `refresh` events come from a full refresh that just ran; `no_files`: only
      -- changelists changed (a shelf, a description), not the opened files.
      if
        d.ws
        and started[d.ws]
        and not d.no_files
        and d.source ~= 'poll'
        and d.source ~= 'refresh'
      then
        require('perforated.poll_follow').on_changed(d)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(ev)
      last_enter[ev.buf] = nil
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
  local follow = package.loaded['perforated.poll_follow']
  if follow then
    follow._reset()
  end
  started, last_enter, last_focus_probe = {}, {}, 0
end

return M
