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
---@field meta table<integer, { change: integer, user: string?, time: string?, desc: string?, client: string? }>  time: 'YYYY/MM/DD hh:mm:ss' (annotate -u)

--- Walk the annotate data records: each line's changelist, and each changelist's user and date
--- (`-u`). The text itself isn't kept (the view shows the buffer), so this is one byte check
--- per record. Long lines arrive in several chunks; a line ends with a chunk ending in "\n".
---@param records table[]
---@return table head, integer count, integer[] cls, table<integer, table> meta
local function annotate_lines(records)
  local head, cls, meta = nil, {}, {}
  local n = 0
  local open_cl = nil -- changelist of a line whose chunks haven't ended yet
  for i = 1, #records do
    local r = records[i]
    local d = r.data
    if d then
      local cl = open_cl
      if not cl then
        cl = tonumber(r.lower) or tonumber(r.upper) or 0
        if r.user and not meta[cl] then
          meta[cl] = { change = cl, user = r.user, time = r.time, client = r.client }
        end
      end
      if d:byte(-1) == 10 then
        n = n + 1
        cls[n] = cl
        open_cl = nil
      else
        open_cl = cl
      end
    elseif r.depotFile and not head then
      head = r
    end
  end
  if open_cl then
    n = n + 1
    cls[n] = open_cl
  end
  return head or {}, n, cls, meta
end
M._annotate_lines = annotate_lines

--- Annotate a revision: `annotate -c -i -u -q [-I] spec`. `-i` follows branches, so a line
--- keeps the change that wrote it rather than the one that branched the file; `-u` gives each
--- line's user and date. One p4 call.
---
--- `descriptions` (for the blame line) also runs `filelog -l -i` in parallel for the
--- changelist descriptions; changelists it doesn't reach are described in one more call.
---@param ws perforated.Workspace
---@param spec string   //depot/path#rev (or a local path)
---@param opts { integrations: boolean?, descriptions: boolean? }?
---@param cb fun(a: perforated.Annotation?, err: string?)
function M.annotate(ws, spec, opts, cb)
  opts = opts or {}
  -- A numbered revision never changes: reuse a recent result (blame line, re-opened views).
  local ckey = spec:match('#%d+$')
    and (
      ws.key
      .. '\0'
      .. spec
      .. (opts.integrations and '\0I' or '')
      .. (opts.descriptions and '\0D' or '')
    )
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
  local ann, descs, errmsg
  local pending = opts.descriptions and 2 or 1
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not ann then
      return cb(nil, errmsg or 'annotate failed')
    end
    if not opts.descriptions then
      return cb(ann)
    end
    local missing, seen = {}, {}
    for _, c in ipairs(ann.cls) do
      local m = ann.meta[c]
      if descs[c] then
        m.desc = descs[c]
      elseif c > 0 and not seen[c] then
        seen[c] = true
        missing[#missing + 1] = tostring(c)
      end
    end
    if #missing == 0 then
      return cb(ann)
    end
    require('perforated.changelists').describe(ws, missing, {}, function(by)
      for ch, d in pairs(by) do
        local m = ann.meta[tonumber(ch)]
        if m then
          m.desc = first_line(d.rec.desc)
        end
      end
      cb(ann)
    end)
  end
  local args = { 'annotate', '-c', '-i', '-u', '-q' }
  if opts.integrations then
    args[#args + 1] = '-I'
  end
  args[#args + 1] = spec
  ws:run(args, {}, function(res)
    local head, count, cls, meta = annotate_lines(res.records)
    if head.depotFile then
      for _, c in ipairs(cls) do
        meta[c] = meta[c] or { change = c }
      end
      ann = {
        depotFile = head.depotFile,
        rev = head.rev,
        change = head.change,
        count = count,
        cls = cls,
        meta = meta,
      }
    else
      errmsg = res.errors[1] or res.warnings[1]
    end
    done()
  end)
  if opts.descriptions then
    local max = tonumber(require('perforated.config').get().annotate.history_max) or 1000
    ws:run({ 'filelog', '-l', '-i', '-m', tostring(max), path }, {}, function(res)
      descs = {}
      for _, rec in ipairs(res.records) do
        if rec.depotFile then
          for _, r in ipairs(parse.indexed(rec, { 'change', 'desc' })) do
            local c = tonumber(r.change)
            if c and not descs[c] then
              descs[c] = first_line(r.desc)
            end
          end
        end
      end
      done()
    end)
  end
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
