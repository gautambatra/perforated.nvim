--- Typed wrappers over p4 commands. Each takes a Workspace and a callback, batches file
--- arguments through `-x -`, and returns parsed data. No UI here.

local M = {}

M.FSTAT_FIELDS = table.concat({
  'depotFile',
  'clientFile',
  'haveRev',
  'headRev',
  'headChange',
  'headType',
  'headAction',
  'type',
  'action',
  'change',
  'unresolved',
  'otherOpen',
  'movedFile',
  'movedRev',
  'ourLock',
  'otherLock',
}, ',')

---@param ws perforated.Workspace
---@param path string
---@return string
local function key(ws, path)
  return ws.icase and path:lower() or path
end
M.key = key

--- Parse a "<path> - <reason>" message into (path, kind).
---@param text string
---@return string? path, 'nosuch'|'notinview'|'other'|nil kind
function M.parse_file_message(text)
  local path, rest = text:match('^(.-) %- (.+)$')
  if not path then
    return nil
  end
  if rest:find('no such file', 1, true) then
    return path, 'nosuch'
  elseif rest:find('not in client view', 1, true) or rest:find('not under client', 1, true) then
    return path, 'notinview'
  end
  return path, 'other'
end

---@class perforated.FstatResult
---@field files table<string, table>   key(clientFile) → record
---@field missing table<string, 'nosuch'|'notinview'|'other'>  key(path) → reason
---@field by_index { rec: table?, missing: string? }[]  per input path, in order
---@field res perforated.RunResult

--- fstat for local paths (batched). Records are keyed by (case-normalised) local path.
---@param ws perforated.Workspace
---@param paths string[]
---@param opts perforated.RunOpts?
---@param cb fun(r: perforated.FstatResult)
function M.fstat(ws, paths, opts, cb)
  opts = vim.tbl_extend('force', { stdin = M.escape_all(paths) }, opts or {})
  opts.globals = { '-x', '-' }
  ws:run({ 'fstat', '-T', M.FSTAT_FIELDS }, opts, function(res)
    local out = { files = {}, missing = {}, res = res }
    for _, rec in ipairs(res.records) do
      if rec.clientFile then
        out.files[key(ws, rec.clientFile)] = rec
      end
    end
    for _, text in ipairs(vim.list_extend(vim.list_extend({}, res.warnings), res.errors)) do
      local p, kind = M.parse_file_message(text)
      if p then
        out.missing[key(ws, M.unescape(p))] = kind
      end
    end
    -- p4 answers `-x -` arguments in order (one record or one message each), which lets us
    -- match results even when p4's path spelling differs from ours (symlinks, /private/tmp).
    out.by_index = {}
    if #(res.all or {}) == #paths then
      for i, rec in ipairs(res.all) do
        if require('perforated.core.parse').is_message(rec) then
          local _, kind = M.parse_file_message(require('perforated.core.parse').message_text(rec))
          out.by_index[i] = { missing = kind or 'other' }
        else
          out.by_index[i] = { rec = rec }
        end
      end
    end
    cb(out)
  end)
end

--- fstat of every file opened in the workspace (one call: `fstat -Ro //client/...`).
--- Concurrent callers share one call, but not across a change (`opened_changed`): a call
--- started before it may not see it. `opts.reuse`: the opened files of a full refresh moments
--- ago (`fresh`) answer instead (pickers).
---@param ws perforated.Workspace
---@param opts (perforated.RunOpts|{ reuse: boolean? })?
---@param cb fun(recs: table[]?, res: perforated.RunResult)
function M.fstat_opened(ws, opts, cb)
  local client = ws:client()
  if not client then
    return vim.schedule(function()
      cb(nil, { ok = false, errors = { 'unknown client' }, records = {}, warnings = {} })
    end)
  end
  if opts and opts.reuse and ws.opened and M.fresh(ws, ws.opened_stamp) then
    local recs = vim.tbl_values(ws.opened)
    table.sort(recs, function(a, b)
      return a.depotFile < b.depotFile
    end)
    return vim.schedule(function()
      cb(recs, { ok = true, records = recs, errors = {}, warnings = {} })
    end)
  end
  opts = vim.tbl_extend('keep', opts or {}, { key = 'fstat-opened:' .. (ws.opened_gen or 0) })
  opts.reuse = nil
  ws:run({ 'fstat', '-Ro', '-T', M.FSTAT_FIELDS, ('//%s/...'):format(client) }, opts, function(res)
    -- "file(s) not opened" is a warning (severity 2): nothing is opened, still ok.
    cb(res.ok and res.records or nil, res)
  end)
end

--- A stamp for state asked for now: it may answer again for `poll.reuse` seconds, until a
--- change (`opened_changed`).
---@param ws perforated.Workspace
---@return { t: integer, gen: integer }
function M.stamp(ws)
  return { t = vim.uv.now(), gen = ws.opened_gen or 0 }
end

--- Whether state with this stamp may answer again (`poll.reuse`: a change made since, or an
--- older answer, means asking).
---@param ws perforated.Workspace
---@param stamp { t: integer, gen: integer }?
---@return boolean
function M.fresh(ws, stamp)
  local reuse = require('perforated.config').get().poll.reuse or 0
  return stamp ~= nil
    and reuse > 0
    and stamp.gen == (ws.opened_gen or 0)
    and vim.uv.now() - stamp.t < reuse * 1000
end

--- Keep this client's pending changelists (from the probe, or `pending_changes`), asked for
--- at `stamp`, for `pending_changes(…, { reuse = true })`.
---@param ws perforated.Workspace
---@param stamp { t: integer, gen: integer }
---@param records table[]
function M.keep_pending(ws, stamp, records)
  ws.pending_kept = { stamp = stamp, records = records }
end

--- The opened files may have changed (a plugin change, or one seen elsewhere): a later
--- `fstat_opened` doesn't share a call started before.
---@param ws perforated.Workspace
function M.opened_changed(ws)
  ws.opened_gen = (ws.opened_gen or 0) + 1
end

--- Decide the depot revision a buffer's working copy should be compared against.
---@param rec table fstat record
---@return string? spec  e.g. //depot/a.c#3; nil = no base (all lines are new)
function M.base_spec(rec)
  local action = rec.action
  if action == 'add' or action == 'branch' then
    return nil
  end
  if action == 'move/add' and rec.movedFile then
    return rec.movedFile .. '#' .. (rec.movedRev or rec.haveRev or 'have')
  end
  if rec.haveRev and rec.haveRev ~= 'none' then
    return rec.depotFile .. '#' .. rec.haveRev
  end
  return nil
end

--- Is this file type diffable as text?
---@param rec table
---@return boolean
function M.is_text(rec)
  local t = rec.type or rec.headType or 'text'
  return not (
    t:find('binary')
    or t:find('apple')
    or t:find('resource')
    or t:find('symlink')
    or t:find('utf16')
  )
end

--- Snapshots and batch prints live in `perforated.p4_batch`, loaded by the views that use them.
function M.snapshot()
  return require('perforated.p4_batch').snapshot()
end
function M.release(snap)
  return require('perforated.p4_batch').release(snap)
end
function M.renew(snap)
  return require('perforated.p4_batch').renew(snap)
end

--- Prints in flight in a batch (`print_batch`): cache key → callbacks of `print`s that wait for it.
local batched = {} ---@type table<string, fun(lines: string[]?)[]>
M._batched = batched

--- Keep printed content: numbered revisions in the content cache, others in `snap`.
local function keep(ws, spec, lines, bytes, snap)
  local ckey = ws:server_key() .. '|' .. spec
  if spec:match('#%d+$') then
    local cache = require('perforated.core.cache').content()
    if snap and not snap.closed and not cache:has(ckey) then
      snap.cached[#snap.cached + 1] = ckey
    end
    cache:set(ckey, lines, bytes + 40 * #lines)
  elseif snap and not snap.closed then
    snap.lines[spec] = lines
  end
end
M._keep = keep

--- Content for a revision spec, as lines. Numeric revisions are immutable and cached; others
--- come from `opts.snapshot` once it has them. A spec a `print_batch` is printing waits for it.
---@param ws perforated.Workspace
---@param spec string  //depot/path#rev | @change | @=shelf
---@param opts (perforated.RunOpts|{ snapshot: perforated.Snapshot? })?
---@param cb fun(lines: string[]?, err: string?)
function M.print(ws, spec, opts, cb)
  local cache = require('perforated.core.cache').content()
  local immutable = spec:match('#%d+$') ~= nil
  local ckey = ws:server_key() .. '|' .. spec
  local snap = opts and opts.snapshot
  local hit = immutable and cache:get(ckey) or (snap and snap.lines[spec])
  if hit then
    return vim.schedule(function()
      cb(hit)
    end)
  end
  if batched[ckey] then
    -- Not in the batch's answer (or it failed): print it alone after all.
    table.insert(batched[ckey], function(lines)
      if lines then
        return cb(lines)
      end
      M.print(ws, spec, opts, cb)
    end)
    return
  end
  opts = vim.tbl_extend('force', { key = 'print:' .. spec }, opts or {})
  opts.tagged = false
  opts.snapshot = nil
  ws:run({ 'print', '-q', spec }, opts, function(res)
    -- Untagged: "no such file" is a warning on stderr with exit 0, so check stderr too.
    local err = vim.trim(res.stderr or '')
    if not res.ok or (err ~= '' and (res.stdout or '') == '') then
      return cb(nil, err ~= '' and err or res.errors[1] or 'p4 print failed')
    end
    local lines = M.split_lines(res.stdout or '')
    keep(ws, spec, lines, #(res.stdout or ''), snap)
    cb(lines)
  end)
end

function M.print_batch(ws, specs, opts, cb)
  return require('perforated.p4_batch').print_batch(ws, specs, opts, cb)
end
function M.print_many(ws, specs, opts, cb)
  return require('perforated.p4_batch').print_many(ws, specs, opts, cb)
end

--- Split file content into lines the way Neovim shows a buffer (CRLF → LF, no final empty line).
---@param text string
---@return string[]
function M.split_lines(text)
  if text == '' then
    return {}
  end
  text = text:gsub('\r\n', '\n')
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

--- Changelists and file commands run on request (`perforated.p4_cmds`, loaded with the first).
---@param ws perforated.Workspace
---@param cb fun(changes: table[]?, err: string?)
---@param scope ('client'|'user')?
---@param opts { reuse: boolean? }?
function M.pending_changes(ws, cb, scope, opts)
  return require('perforated.p4_cmds').pending_changes(ws, cb, scope, opts)
end
function M.new_change(ws, desc, cb)
  return require('perforated.p4_cmds').new_change(ws, desc, cb)
end
function M.edit(ws, paths, change, cb, busy)
  return require('perforated.p4_cmds').edit(ws, paths, change, cb, busy)
end
function M.add(ws, paths, change, cb, busy)
  return require('perforated.p4_cmds').add(ws, paths, change, cb, busy)
end
function M.reconcile_add(ws, paths, change, cb, busy)
  return require('perforated.p4_cmds').reconcile_add(ws, paths, change, cb, busy)
end
function M.revert(ws, paths, opts, cb)
  return require('perforated.p4_cmds').revert(ws, paths, opts, cb)
end

--- Newest submitted change touching any of the given depot files (one call).
---@param ws perforated.Workspace
---@param depot_files string[]
---@param cb fun(max: integer?, changes: table<string, table>)  changes keyed by change number
function M.latest_changes(ws, depot_files, cb)
  if #depot_files == 0 then
    return vim.schedule(function()
      cb(nil, {})
    end)
  end
  ws:run({ 'changes', '-m1', '-s', 'submitted' }, {
    globals = { '-x', '-' },
    stdin = depot_files,
    priority = 3,
  }, function(res)
    local max, by = nil, {}
    for _, rec in ipairs(res.records) do
      local n = tonumber(rec.change)
      if n then
        by[rec.change] = rec
        max = math.max(max or 0, n)
      end
    end
    cb(res.ok and max or nil, by)
  end)
end

--- Escape p4's wildcard characters in a local file path (`@` `#` `%` `*`), so a file such as
--- `icon@2x.png` isn't read as a revision specifier. Depot paths (`//…`) are returned as they
--- are: p4 reports them already escaped. Not for `add` (it takes literal names with `-f`) or
--- for paths that carry a revision the user typed.
---@param path string
---@return string
function M.escape(path)
  if path:sub(1, 2) == '//' then
    return path
  end
  return (path:gsub('%%', '%%25'):gsub('@', '%%40'):gsub('#', '%%23'):gsub('%*', '%%2A'))
end

--- Undo `escape` (p4 echoes escaped paths in its messages).
---@param path string
---@return string
function M.unescape(path)
  return (path:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- `escape` over a list.
---@param paths string[]
---@return string[]
function M.escape_all(paths)
  return vim.tbl_map(M.escape, paths)
end

return M
