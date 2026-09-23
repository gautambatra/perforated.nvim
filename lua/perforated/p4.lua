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

--- Files opened by the user on every client (`opened -a -u`): { depotFile, action, change,
--- client, rev, type, … }. Used for the "all my clients" scope.
---@param ws perforated.Workspace
---@param cb fun(recs: table[]?, err: string?)
function M.opened_by_user(ws, cb)
  local user = ws:user()
  if not user then
    return vim.schedule(function()
      cb(nil, 'unknown user')
    end)
  end
  ws:run({ 'opened', '-a', '-u', user }, { key = 'opened-user' }, function(res)
    cb(res.ok and res.records or nil, res.errors[1])
  end)
end

--- Shelved files of several changelists in one call (`describe -S -s cl…`).
---@param ws perforated.Workspace
---@param changes string[]
---@param cb fun(by_change: table<string, table[]>)  change → { depotFile, action, rev, type }
function M.shelved_files(ws, changes, cb)
  if #changes == 0 then
    return vim.schedule(function()
      cb({})
    end)
  end
  ws:run(vim.list_extend({ 'describe', '-S', '-s' }, changes), {}, function(res)
    local out = {}
    for _, rec in ipairs(res.records) do
      if rec.change then
        out[rec.change] =
          require('perforated.core.parse').indexed(rec, { 'depotFile', 'action', 'rev', 'type' })
      end
    end
    cb(out)
  end)
end

--- Describe changelists (files without diffs): change → { rec, files = { … } }.
---@param ws perforated.Workspace
---@param changes string[]
---@param opts { shelved: boolean? }?
---@param cb fun(by_change: table<string, { rec: table, files: table[] }>)
function M.describe(ws, changes, opts, cb)
  local args = { 'describe', '-s' }
  if opts and opts.shelved then
    args[#args + 1] = '-S'
  end
  ws:run(vim.list_extend(args, changes), {}, function(res)
    local out = {}
    for _, rec in ipairs(res.records) do
      if rec.change then
        out[rec.change] = {
          rec = rec,
          files = require('perforated.core.parse').indexed(
            rec,
            { 'depotFile', 'action', 'rev', 'type' }
          ),
        }
      end
    end
    cb(out)
  end)
end

--- Submitted changelists, newest first. `before` pages backwards (changes at or before it).
---@param ws perforated.Workspace
---@param opts { user: string?, path: string?, max: integer?, before: integer? }
---@param cb fun(changes: table[]?, err: string?)
function M.submitted_changes(ws, opts, cb)
  local args = { 'changes', '-s', 'submitted', '-l', '-m', tostring(opts.max or 50) }
  if opts.user then
    vim.list_extend(args, { '-u', opts.user })
  end
  local path = opts.path
  if not path then
    local client = ws:client()
    path = client and ('//%s/...'):format(client) or nil
  end
  if path then
    if opts.before then
      path = path .. '@' .. opts.before
    end
    args[#args + 1] = path
  elseif opts.before then
    args[#args + 1] = '@' .. opts.before
  end
  ws:run(args, {}, function(res)
    if not res.ok then
      return cb(nil, res.errors[1] or vim.trim(res.stderr))
    end
    cb(res.records)
  end)
end

--- 'pending' | 'submitted' | 'shelved' | nil for a changelist number.
---@param ws perforated.Workspace
---@param change string
---@param cb fun(status: string?)
function M.change_status(ws, change, cb)
  ws:run({ 'describe', '-s', '-m', '1', change }, {}, function(res)
    local rec = res.records[1]
    cb(rec and rec.status or nil)
  end)
end

--- Move opened files to another changelist.
function M.reopen(ws, paths, change, cb)
  ws:run({ 'reopen', '-c', change or 'default' }, { globals = { '-x', '-' }, stdin = paths }, cb)
end

--- Workspace reconcile preview (`p4 status`): files to add / edit / delete. Can be slow on large
--- workspaces: no timeout, and the caller may kill it (returns the vim.SystemObj via runner).
---@param ws perforated.Workspace
---@param path string?  default //client/...
---@param cb fun(recs: table[]?, err: string?)
function M.status(ws, path, cb)
  local client = ws:client()
  path = path or (client and ('//%s/...'):format(client))
  if not path then
    return vim.schedule(function()
      cb(nil, 'unknown client')
    end)
  end
  ws:run({ 'status', path }, { timeout = 0, priority = 3 }, function(res)
    if res.code ~= 0 and #res.records == 0 then
      return cb(nil, res.errors[1] or vim.trim(res.stderr))
    end
    local recs = vim.tbl_filter(function(r)
      return r.action ~= nil and r.change == nil -- opened files aren't "to reconcile"
    end, res.records)
    cb(recs)
  end)
end

--- Change spec as text (untagged: specs can't round-trip through -Mj).
---@param ws perforated.Workspace
---@param change string
---@param opts { submitted: boolean? }?
---@param cb fun(text: string?, err: string?)
function M.change_spec(ws, change, opts, cb)
  local args = { 'change', '-o' }
  if opts and opts.submitted then
    args[#args + 1] = '-u'
  end
  args[#args + 1] = change
  ws:run(args, { tagged = false }, function(res)
    if not res.ok or (res.stdout or '') == '' then
      return cb(nil, vim.trim(res.stderr ~= '' and res.stderr or (res.stdout or '')))
    end
    cb(res.stdout)
  end)
end

--- Save a change spec (`change -i`, `-u` for the owner's submitted CL, `-f` to force).
---@param ws perforated.Workspace
---@param text string
---@param opts { submitted: boolean?, force: boolean? }?
---@param cb fun(ok: boolean, msg: string, change: string?)
function M.save_spec(ws, text, opts, cb)
  local args = { 'change' }
  if opts and opts.force then
    args[#args + 1] = '-f'
  elseif opts and opts.submitted then
    args[#args + 1] = '-u'
  end
  args[#args + 1] = '-i'
  ws:run(args, { tagged = false, stdin = text }, function(res)
    local out = vim.trim((res.stdout or '') .. '\n' .. (res.stderr or ''))
    local cl = out:match('Change (%d+) created') or out:match('Change (%d+) updated')
    cb(res.ok and cl ~= nil, out, cl)
  end)
end

--- Replace the Description field of a change spec, keeping everything else byte-for-byte.
---@param spec string
---@param desc string
---@return string
function M.spec_set_description(spec, desc)
  local lines = vim.split(spec, '\n', { plain = true })
  local out, i, done = {}, 1, false
  while i <= #lines do
    local l = lines[i]
    if not done and l:match('^Description:') then
      out[#out + 1] = 'Description:'
      for _, d in ipairs(vim.split(desc, '\n', { plain = true })) do
        out[#out + 1] = '\t' .. d
      end
      i = i + 1
      -- Skip the old description body (indented lines and blank lines up to the next field).
      while i <= #lines and (lines[i]:match('^%s') or lines[i] == '') do
        if lines[i] == '' and lines[i + 1] and lines[i + 1]:match('^%S') then
          break
        end
        i = i + 1
      end
      done = true
    else
      out[#out + 1] = l
      i = i + 1
    end
  end
  return table.concat(out, '\n')
end

--- Description field of a change spec (tabs stripped).
---@param spec string
---@return string
function M.spec_get_description(spec)
  local desc, inside = {}, false
  for _, l in ipairs(vim.split(spec, '\n', { plain = true })) do
    if inside then
      if l:match('^%S') then
        break
      end
      desc[#desc + 1] = (l:gsub('^\t', ''))
    elseif l:match('^Description:') then
      inside = true
    end
  end
  while #desc > 0 and vim.trim(desc[#desc]) == '' do
    desc[#desc] = nil
  end
  return table.concat(desc, '\n')
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
