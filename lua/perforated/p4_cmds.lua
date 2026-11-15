--- p4 commands run on request: pending changelists (kept for reuse), a new changelist, and
--- the file commands edit/add/revert. `perforated.p4` forwards to them; they load with the
--- first one, not at startup.

local p4 = require('perforated.p4')

local M = {}

--- Pending changelists (full descriptions) of this client, or of all the user's clients.
--- Records carry `shelved = ''` when the CL has shelved files. `opts.reuse`: this client's
--- list fetched moments ago (`fresh`) answers instead (pickers, prompts).
---@param ws perforated.Workspace
---@param cb fun(changes: table[]?, err: string?)
---@param scope ('client'|'user')?
---@param opts { reuse: boolean? }?
function M.pending_changes(ws, cb, scope, opts)
  local client_scope = scope ~= 'user'
  local kept = ws.pending_kept
  if client_scope and opts and opts.reuse and kept and p4.fresh(ws, kept.stamp) then
    return vim.schedule(function()
      cb(vim.list_extend({}, kept.records))
    end)
  end
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
  local stamp = p4.stamp(ws)
  ws:run(args, { key = 'pending:' .. (scope or 'client') }, function(res)
    if not res.ok then
      return cb(nil, res.errors[1] or vim.trim(res.stderr))
    end
    if client_scope then
      p4.keep_pending(ws, stamp, res.records)
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
        ws.pending_kept = nil -- the list lacks it
        return cb(cl)
      end
      cb(nil, res.errors[1] or vim.trim((res.stdout or '') .. res.stderr))
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
---@param effect string  for the warning when it's stopped, e.g. 'reverted'
---@param busy string?  the pop-up
-- `escape = false` for `add`, which takes file names literally.
local function file_cmd(ws, cmd, paths, cb, effect, busy, escape)
  local stdin = escape == false and paths or p4.escape_all(paths)
  local title = ('%s %s'):format(
    cmd[1],
    #paths == 1 and (paths[1]:match('[^/]+/%.%.%.$') or vim.fs.basename(paths[1]))
      or (#paths .. ' files')
  )
  require('perforated.jobs').run(ws, title, cmd, {
    globals = { '-x', '-' },
    stdin = stdin,
    busy = busy,
    effect = effect,
    single = #paths == 1,
    -- A `<dir>/...` path: how many files it holds isn't known.
    total = not vim.iter(paths):any(function(f)
      return f:find('...', 1, true) ~= nil
    end) and #paths or nil,
  }, cb)
end

function M.edit(ws, paths, change, cb, busy)
  file_cmd(ws, vim.list_extend({ 'edit' }, change_args(change)), paths, cb, 'opened', busy)
end

function M.add(ws, paths, change, cb, busy)
  local cmd = { 'add' }
  for _, p in ipairs(paths) do
    if p:find('[@#%%*]') then
      cmd[#cmd + 1] = '-f' -- names with p4 wildcards are only accepted literally with -f
      break
    end
  end
  file_cmd(ws, vim.list_extend(cmd, change_args(change)), paths, cb, 'opened', busy, false)
end

--- Open for add the files under `paths` (wildcards) that aren't in the depot yet.
function M.reconcile_add(ws, paths, change, cb, busy)
  file_cmd(
    ws,
    vim.list_extend({ 'reconcile', '-a' }, change_args(change)),
    paths,
    cb,
    'opened',
    busy
  )
end

---@param opts { unchanged: boolean?, busy: string? }?
function M.revert(ws, paths, opts, cb)
  local cmd = { 'revert' }
  if opts and opts.unchanged then
    cmd[#cmd + 1] = '-a'
  end
  file_cmd(ws, cmd, paths, cb, 'reverted', opts and opts.busy)
end

return M
