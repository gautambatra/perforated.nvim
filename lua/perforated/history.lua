--- M3 queries: file history (filelog), annotate, the Swarm URL. No UI here.

local parse = require('perforated.core.parse')

local M = {}

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

local FILELOG_FIELDS =
  { 'rev', 'change', 'action', 'time', 'user', 'client', 'desc', 'type', 'fileSize' }

---@class perforated.Rev
---@field depotFile string
---@field rev string
---@field change string
---@field action string
---@field time string?
---@field user string?
---@field client string?
---@field desc string?
---@field type string?
---@field from { how: string, file: string, srev: string?, erev: string? }?  first integration record

--- Revisions of a file, newest first (the file itself, then — with `follow` — the files it was
--- branched from). One `filelog -l [-i] -m N` call; `before` pages backwards (`path#1,#before`).
---@param ws perforated.Workspace
---@param path string  depot or local path (no revision)
---@param opts { max: integer?, before: integer?, follow: boolean? }?
---@param cb fun(revs: perforated.Rev[]?, err: string?)
function M.filelog(ws, path, opts, cb)
  opts = opts or {}
  local args = { 'filelog', '-l' }
  if opts.follow ~= false then
    args[#args + 1] = '-i'
  end
  vim.list_extend(args, { '-m', tostring(opts.max or 100) })
  args[#args + 1] = opts.before and ('%s#1,#%d'):format(path, opts.before) or path
  ws:run(args, {}, function(res)
    if not res.ok and #res.records == 0 then
      return cb(nil, res.errors[1] or 'filelog failed')
    end
    local out = {}
    for _, rec in ipairs(res.records) do
      if rec.depotFile then
        local revs = parse.indexed(
          rec,
          vim.list_extend(vim.deepcopy(FILELOG_FIELDS), { 'how', 'file', 'srev', 'erev' })
        )
        for _, r in ipairs(revs) do
          r.depotFile = rec.depotFile
          if r.sub and r.sub[1] then
            local s = r.sub[1]
            r.from = { how = s.how, file = s.file, srev = s.srev, erev = s.erev }
          end
          r.sub = nil
          out[#out + 1] = r
        end
      end
    end
    cb(out)
  end)
end

local CACHE_SIZE = 8
local cache = {} ---@type { key: string, ann: perforated.Annotation }[]  most recent first
local waiting = {} ---@type table<string, function[]>

--- Forget cached annotations (tests, :P4 refresh).
function M.clear_cache()
  cache, waiting = {}, {}
end

---@class perforated.Annotation
---@field depotFile string
---@field rev string
---@field change string?
---@field count integer         number of lines
---@field cls integer[]           line → changelist that last changed it
---@field meta table<integer, { change: integer, rev: string?, user: string?, time: string?, desc: string?, client: string? }>

--- Split the (possibly chunked) annotate data records into lines with their changelist.
---@param records table[]
---@return table head, string[] lines, integer[] cls
local function annotate_lines(records)
  local head, lines, cls = nil, {}, {}
  local pending = nil -- a data chunk without a trailing newline (long lines are split)
  local pending_cl
  for _, r in ipairs(records) do
    if r.depotFile and not r.data then
      head = head or r
    elseif r.data then
      local d = r.data
      local cl = tonumber(r.lower or r.upper) or 0
      if pending then
        d, cl = pending .. d, pending_cl
        pending = nil
      end
      if d:sub(-1) == '\n' then
        d = d:sub(1, -2)
        if d:sub(-1) == '\r' then
          d = d:sub(1, -2)
        end
        lines[#lines + 1] = d
        cls[#cls + 1] = cl
      else
        pending, pending_cl = d, cl
      end
    end
  end
  if pending then
    lines[#lines + 1] = pending
    cls[#cls + 1] = pending_cl
  end
  return head or {}, lines, cls
end
M._annotate_lines = annotate_lines

--- Annotate a revision: `annotate -c -q [-I] spec` and `filelog -l [-i] path` in parallel
--- (two p4 calls, whatever the file's size or history). Changelists that the file's own
--- history doesn't cover (only possible with `integrations`) are described in one more call.
---@param ws perforated.Workspace
---@param spec string   //depot/path#rev (or a local path)
---@param opts { integrations: boolean? }?
---@param cb fun(a: perforated.Annotation?, err: string?)
function M.annotate(ws, spec, opts, cb)
  opts = opts or {}
  -- A numbered revision never changes: reuse a recent result (blame line, re-opened views).
  local ckey = spec:match('#%d+$')
    and (ws.key .. '\0' .. spec .. (opts.integrations and '\0I' or ''))
  if ckey then
    for i, e in ipairs(cache) do
      if e.key == ckey then
        table.remove(cache, i)
        table.insert(cache, 1, e)
        return vim.schedule(function()
          cb(e.ann)
        end)
      end
    end
    local inflight = waiting[ckey]
    if inflight then
      inflight[#inflight + 1] = cb
      return
    end
    waiting[ckey] = { cb }
    local orig = cb
    cb = function(a, err)
      local cbs = waiting[ckey] or { orig }
      waiting[ckey] = nil
      if a then
        table.insert(cache, 1, { key = ckey, ann = a })
        cache[CACHE_SIZE + 1] = nil
      end
      for _, f in ipairs(cbs) do
        f(a, err)
      end
    end
  end
  local path = spec:gsub('[#@].*$', '')
  local ann, revs, errmsg
  local pending = 2
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not ann then
      return cb(nil, errmsg or 'annotate failed')
    end
    local meta = {}
    for _, r in ipairs(revs or {}) do
      local c = tonumber(r.change)
      if c and not meta[c] and r.depotFile == ann.depotFile then
        meta[c] = {
          change = c,
          rev = r.rev,
          user = r.user,
          time = r.time,
          desc = first_line(r.desc),
          client = r.client,
        }
      end
    end
    for _, r in ipairs(revs or {}) do -- ancestors (branch sources) second
      local c = tonumber(r.change)
      if c and not meta[c] then
        meta[c] =
          { change = c, user = r.user, time = r.time, desc = first_line(r.desc), client = r.client }
      end
    end
    ann.meta = meta
    local missing, seen = {}, {}
    for _, c in ipairs(ann.cls) do
      if c > 0 and not meta[c] and not seen[c] then
        seen[c] = true
        missing[#missing + 1] = tostring(c)
      end
    end
    if #missing == 0 then
      return cb(ann)
    end
    require('perforated.changelists').describe(ws, missing, {}, function(by)
      for ch, d in pairs(by) do
        local c = tonumber(ch)
        meta[c] = {
          change = c,
          user = d.rec.user,
          time = d.rec.time,
          desc = first_line(d.rec.desc),
          client = d.rec.client,
        }
      end
      cb(ann)
    end)
  end
  local args = { 'annotate', '-c', '-q' }
  if opts.integrations then
    args[#args + 1] = '-I'
  end
  args[#args + 1] = spec
  ws:run(args, {}, function(res)
    local head, lines, cls = annotate_lines(res.records)
    if head.depotFile then
      ann = {
        depotFile = head.depotFile,
        rev = head.rev,
        change = head.change,
        count = #lines,
        cls = cls,
      }
    else
      errmsg = res.errors[1] or res.warnings[1]
    end
    done()
  end)
  -- History for the CL metadata; a file's own history covers every line unless -I is used.
  local max = tonumber(require('perforated.config').get().annotate.history_max) or 1000
  ws:run({ 'filelog', '-l', '-i', '-m', tostring(max), path }, {}, function(res)
    revs = {}
    for _, rec in ipairs(res.records) do
      if rec.depotFile then
        for _, r in ipairs(parse.indexed(rec, FILELOG_FIELDS)) do
          r.depotFile = rec.depotFile
          revs[#revs + 1] = r
        end
      end
    end
    done()
  end)
end

--- The Swarm URL for this server (config `swarm.url`, else the `P4.Swarm.URL` property).
--- Asked once per workspace per session.
---@param ws perforated.Workspace
---@param cb fun(url: string?)
function M.swarm_url(ws, cb)
  local cfg = require('perforated.config').get().swarm.url
  if cfg and cfg ~= '' then
    return vim.schedule(function()
      cb((cfg:gsub('/+$', '')))
    end)
  end
  if ws.swarm_url ~= nil then
    return vim.schedule(function()
      cb(ws.swarm_url or nil)
    end)
  end
  ws:run({ 'property', '-l', '-n', 'P4.Swarm.URL' }, {}, function(res)
    local url = res.records[1] and res.records[1].value
    ws.swarm_url = url and url ~= '' and (url:gsub('/+$', '')) or false
    cb(ws.swarm_url or nil)
  end)
end

--- Open (or copy) the Swarm review page of a changelist.
---@param ws perforated.Workspace
---@param change string
---@param copy boolean?
function M.swarm(ws, change, copy)
  M.swarm_url(ws, function(base)
    if not base then
      return vim.notify(
        '[perforated] no Swarm URL (set swarm.url, or the server property P4.Swarm.URL)',
        vim.log.levels.WARN
      )
    end
    local url = ('%s/changes/%s'):format(base, change)
    if copy then
      vim.fn.setreg('"', url)
      pcall(vim.fn.setreg, '+', url)
      vim.notify('[perforated] copied ' .. url)
    else
      vim.ui.open(url)
    end
  end)
end

return M
