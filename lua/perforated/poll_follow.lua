--- Following the plugin's own changes (`User PerforatedChanged`), for `poll`: after a burst of
--- events, one refresh of the opened files the events named (or of every one), and the
--- answer for those waiting on it (`settled`). Loaded with the first change, not at startup.

local p4 = require('perforated.p4')

local M = {}

-- Following the plugin's own changes, per workspace key: the settle timer, whether a refresh
-- is running or owed, when the newest event came, and when the last refresh started.
-- `owed`: an event not answered yet; `files`: what it named (path set), or `all`: everything;
-- `waiters`: callers of `settled`.
local follow = {} ---@type table<string, { timer: uv.uv_timer_t, running: boolean, again: boolean, event: integer, started: integer, owed: boolean, files: table<string, true>?, all: boolean, waiters: fun(recs: table[]?, res: perforated.RunResult?)[] }>
-- Refreshes running, per workspace key.
local inflight = {} ---@type table<string, integer>

--- How long a burst of `Changed` events may last before the opened files are asked again.
M.FOLLOW_MS = 300
--- The same, when the events named their files (a few small `fstat`s, soon).
M.FOLLOW_FILES_MS = 30

---@param opened table<string, table>
---@return table[]
local function sorted(opened)
  local recs = vim.tbl_values(opened)
  table.sort(recs, function(a, b)
    return a.depotFile < b.depotFile
  end)
  return recs
end

--- The opened files after a change that named `files` (local or depot paths): one `fstat` of
--- those, merged into `ws.opened` (a file no longer opened drops out). `named`: the answer per
--- local path key, for their buffers.
---@param ws perforated.Workspace
---@param files string[]
---@param opts { timeout: integer? }
---@param cb fun(recs: table[]?, res: perforated.RunResult, named: table<string, { rec: table?, missing: string? }>?)
function M.opened_with(ws, files, opts, cb)
  p4.fstat(ws, files, { priority = 1, timeout = opts.timeout }, function(r)
    if not r.res.ok and next(r.files) == nil and next(r.missing) == nil then
      return cb(nil, r.res)
    end
    local by_depot = {}
    for _, rec in ipairs(r.res.records) do
      if rec.depotFile then
        by_depot[rec.depotFile] = rec
      end
    end
    local opened, named = vim.tbl_extend('force', {}, ws.opened), {}
    for i, path in ipairs(files) do
      local k = p4.key(ws, path)
      local pos = r.by_index[i] or {}
      local rec = (path:match('^//') and by_depot[path]) or r.files[k] or pos.rec
      if rec then
        opened[rec.depotFile] = rec.action and rec or nil
        if rec.clientFile then
          named[p4.key(ws, rec.clientFile)] = { rec = rec }
        end
      else
        -- Not in the depot (a reverted add) or not in the view: not opened either.
        for depot, o in pairs(opened) do
          if depot == path or (o.clientFile and p4.key(ws, o.clientFile) == k) then
            opened[depot] = nil
          end
        end
        named[k] = { missing = r.missing[k] or pos.missing }
      end
    end
    cb(sorted(opened), r.res, named)
  end)
end

--- Answer the `settled` callers, once no change is owed an answer and no refresh runs.
---@param ws perforated.Workspace
---@param recs table[]?
---@param res perforated.RunResult?
local function serve(ws, recs, res)
  local f = follow[ws.key]
  if not f or f.owed or (inflight[ws.key] or 0) > 0 or #f.waiters == 0 then
    return
  end
  local waiters = f.waiters
  f.waiters = {}
  for _, w in ipairs(waiters) do
    w(recs, res)
  end
end

--- A refresh starts: whether a change since the last one explains what it finds.
---@param ws perforated.Workspace
---@return boolean
function M.begin(ws)
  local f = follow[ws.key]
  local explained = f ~= nil and f.event > f.started
  if f then
    f.started = vim.uv.hrtime() -- answers every event before this moment
  end
  inflight[ws.key] = (inflight[ws.key] or 0) + 1
  return explained
end

--- A refresh that `begin` counted ends.
---@param ws perforated.Workspace
---@param recs table[]?
---@param res perforated.RunResult?
function M.finish(ws, recs, res)
  inflight[ws.key] = (inflight[ws.key] or 1) - 1
  serve(ws, recs, res)
end

--- The opened files once the plugin's changes so far are answered: waits for the follow-up
--- refresh a change is owed (and any refresh running), else the opened files known. The client
--- view takes its opened files from here after a change, so they're asked for once.
---@param ws perforated.Workspace
---@param cb fun(recs: table[]?, res: perforated.RunResult?)
function M.settled(ws, cb)
  local f = follow[ws.key]
  if f and (f.owed or (inflight[ws.key] or 0) > 0) then
    table.insert(f.waiters, cb)
    return
  end
  if not ws.opened then
    return M.refresh(
      ws,
      { notify = false, timeout = require('perforated.config').get().runner.timeout },
      cb
    )
  end
  local recs = sorted(ws.opened)
  vim.schedule(function()
    cb(recs)
  end)
end

--- After the plugin changed something (`User PerforatedChanged`), one `fstat` brings the
--- opened-file counts, buffers and statuslines up to date, once the burst has settled: of the
--- files the events named, or `fstat -Ro` of every opened file when one didn't. Skipped when
--- a full refresh already started after the newest event (a sync runs its own).
---@param ws perforated.Workspace
local function follow_up(ws)
  local f = follow[ws.key]
  if f.running then
    f.again = true
    return
  end
  if not f.owed then
    return
  end
  local files = not f.all and f.files and vim.tbl_keys(f.files) or nil
  f.owed, f.files, f.all = false, nil, false
  if not files and f.started >= f.event then
    return serve(ws, ws.opened and sorted(ws.opened)) -- (or when that refresh ends)
  end
  if files then
    table.sort(files)
  end
  f.running = true
  -- Asked for by an action: the interactive timeout, so a slow server mustn't empty the view.
  local timeout = require('perforated.config').get().runner.timeout
  require('perforated.poll').refresh(ws, { files = files, timeout = timeout }, function()
    f.running = false
    if f.again then
      f.again = false
      follow_up(ws)
    end
  end)
end

--- A `Changed` event the poll follows (its workspace watched; not `poll`, `refresh` or
--- `no_files`): owe a follow-up refresh, of the files named or of everything.
---@param data { ws: string, files: string[]? }
function M.on_changed(data)
  local ws = require('perforated.core.workspace').get(data.ws)
  if not ws then
    return
  end
  local f = follow[ws.key]
  if not f then
    f = {
      timer = vim.uv.new_timer(),
      running = false,
      again = false,
      event = 0,
      started = 0,
      owed = false,
      all = false,
      waiters = {},
    }
    follow[ws.key] = f
  end
  f.event, f.owed = vim.uv.hrtime(), true
  if data.files then
    f.files = f.files or {}
    for _, p in ipairs(data.files) do
      f.files[p] = true
    end
  else
    f.all = true
  end
  f.timer:stop()
  f.timer:start(
    f.all and M.FOLLOW_MS or M.FOLLOW_FILES_MS,
    0,
    vim.schedule_wrap(function()
      follow_up(ws)
    end)
  )
end

--- Test helper: stop the timers, forget every workspace.
function M._reset()
  for _, f in pairs(follow) do
    f.timer:stop()
    f.timer:close()
  end
  follow, inflight = {}, {}
end

return M
