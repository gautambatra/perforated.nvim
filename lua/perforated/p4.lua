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
  opts = vim.tbl_extend('force', { stdin = paths }, opts or {})
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
        out.missing[key(ws, p)] = kind
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
---@param ws perforated.Workspace
---@param opts perforated.RunOpts?
---@param cb fun(recs: table[]?, res: perforated.RunResult)
function M.fstat_opened(ws, opts, cb)
  local client = ws:client()
  if not client then
    return vim.schedule(function()
      cb(nil, { ok = false, errors = { 'unknown client' }, records = {}, warnings = {} })
    end)
  end
  ws:run({ 'fstat', '-Ro', '-T', M.FSTAT_FIELDS, ('//%s/...'):format(client) }, opts, function(res)
    -- "file(s) not opened" is a warning (severity 2): nothing is opened, still ok.
    cb(res.ok and res.records or nil, res)
  end)
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

--- Content for a revision spec, as lines. Numeric revisions are immutable and cached.
---@param ws perforated.Workspace
---@param spec string  //depot/path#rev | @change | @=shelf
---@param opts perforated.RunOpts?
---@param cb fun(lines: string[]?, err: string?)
function M.print(ws, spec, opts, cb)
  local cache = require('perforated.core.cache').content()
  local immutable = spec:match('#%d+$') ~= nil
  local ckey = ws:server_key() .. '|' .. spec
  if immutable then
    local hit = cache:get(ckey)
    if hit then
      return vim.schedule(function()
        cb(hit)
      end)
    end
  end
  opts = vim.tbl_extend('force', { key = 'print:' .. spec }, opts or {})
  opts.tagged = false
  ws:run({ 'print', '-q', spec }, opts, function(res)
    -- Untagged: "no such file" is a warning on stderr with exit 0, so check stderr too.
    local err = vim.trim(res.stderr or '')
    if not res.ok or (err ~= '' and (res.stdout or '') == '') then
      return cb(nil, err ~= '' and err or 'p4 print failed')
    end
    local lines = M.split_lines(res.stdout or '')
    if immutable then
      cache:set(ckey, lines, #(res.stdout or '') + 40 * #lines)
    end
    cb(lines)
  end)
end

--- Print several revision specs in one call (-Mj: header record, data chunks, next header…).
---@param ws perforated.Workspace
---@param specs string[]
---@param opts perforated.RunOpts?
---@param cb fun(contents: table<string, string[]>)  keyed by "depotFile#rev"
function M.print_many(ws, specs, opts, cb)
  opts = vim.tbl_extend('force', { stdin = specs }, opts or {})
  opts.globals = { '-x', '-' }
  ws:run({ 'print', '-q' }, opts, function(res)
    local out, cur, chunks = {}, nil, {}
    local function flush()
      if cur then
        out[cur] = M.split_lines(table.concat(chunks))
      end
      chunks = {}
    end
    for _, rec in ipairs(res.records) do
      if rec.depotFile and rec.rev then
        flush()
        cur = rec.depotFile .. '#' .. rec.rev
      elseif rec.data and cur then
        chunks[#chunks + 1] = rec.data
      end
    end
    flush()
    cb(out)
  end)
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

--- Pending changelists (full descriptions) of this client, or of all the user's clients.
--- Records carry `shelved = ''` when the CL has shelved files.
---@param ws perforated.Workspace
---@param cb fun(changes: table[]?, err: string?)
---@param scope ('client'|'user')?
function M.pending_changes(ws, cb, scope)
  local client, user = ws:client(), ws:user()
  local filter
  if scope == 'user' then
    filter = user and { '-u', user }
  else
    filter = client and { '-c', client }
  end
  if not filter then
    return vim.schedule(function()
      cb(nil, 'unknown client/user')
    end)
  end
  local args = vim.list_extend({ 'changes', '-s', 'pending', '-l' }, filter)
  ws:run(args, { key = 'pending:' .. (scope or 'client') }, function(res)
    if not res.ok then
      return cb(nil, res.errors[1] or vim.trim(res.stderr))
    end
    cb(res.records)
  end)
end

--- Create an empty pending changelist. Specs are sent untagged (-Mj breaks `change -i`).
---@param ws perforated.Workspace
---@param desc string
---@param cb fun(change: string?, err: string?)
function M.new_change(ws, desc, cb)
  local lines = { 'Change: new', 'Description:' }
  for _, l in ipairs(vim.split(desc, '\n', { plain = true })) do
    lines[#lines + 1] = '\t' .. l
  end
  ws:run(
    { 'change', '-i' },
    { tagged = false, stdin = table.concat(lines, '\n') .. '\n' },
    function(res)
      local cl = res.ok and (res.stdout or ''):match('Change (%d+) created')
      if cl then
        return cb(cl)
      end
      cb(nil, vim.trim((res.stdout or '') .. res.stderr))
    end
  )
end

---@param change string?
---@return string[]
local function change_args(change)
  if change and change ~= 'default' then
    return { '-c', change }
  end
  return {}
end

--- Run a file-mutating command over many paths.
---@param ws perforated.Workspace
---@param cmd string[]  e.g. { 'edit', '-c', '12' }
---@param paths string[]
---@param cb fun(res: perforated.RunResult)
local function file_cmd(ws, cmd, paths, cb)
  ws:run(cmd, { globals = { '-x', '-' }, stdin = paths }, cb)
end

function M.edit(ws, paths, change, cb)
  file_cmd(ws, vim.list_extend({ 'edit' }, change_args(change)), paths, cb)
end

function M.add(ws, paths, change, cb)
  file_cmd(ws, vim.list_extend({ 'add' }, change_args(change)), paths, cb)
end

---@param opts { unchanged: boolean? }?
function M.revert(ws, paths, opts, cb)
  local cmd = { 'revert' }
  if opts and opts.unchanged then
    cmd[#cmd + 1] = '-a'
  end
  file_cmd(ws, cmd, paths, cb)
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

return M
