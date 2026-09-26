--- Changelist queries used by the views (client view, describe, changes, CL editor, diff tab).
--- Kept out of `perforated.p4` so the activation path (buffers, signs, check-out) doesn't load
--- them.

local M = {}

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
---@param path string|string[]|nil  default //client/...
---@param run_opts table?  extra ws:run options (jobs: on_spawn / on_record)
---@param cb fun(recs: table[]?, err: string?)
function M.status(ws, path, cb, run_opts)
  local client = ws:client()
  local paths = type(path) == 'table' and path
    or { path or (client and ('//%s/...'):format(client)) }
  if #paths == 0 or not paths[1] then
    return vim.schedule(function()
      cb(nil, 'unknown client')
    end)
  end
  local opts = vim.tbl_extend('force', { timeout = 0, priority = 3 }, run_opts or {})
  ws:run(vim.list_extend({ 'status' }, paths), opts, function(res)
    if res.cancelled then
      return cb(nil, 'cancelled')
    end
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

return M
