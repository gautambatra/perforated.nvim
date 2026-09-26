--- Experimental, opt-in (`lsp = { enabled = true }`): Perforce actions as LSP code actions.
---
--- An in-process language server (no external process) attaches to Perforce buffers and
--- answers `textDocument/codeAction` with what applies to the file and the cursor line —
--- check out, diff, revert, history, annotate, time-lapse, the line's changelist, hunk
--- actions, … — so Neovim's code-action menu (`gra`) offers them next to your language
--- server's. Choosing one runs it client-side (vim.lsp.commands).

local M = {}

local NAME = 'perforated'

--- Commands: id → { title, run(buf, line), when(st, line) }.
local COMMANDS = {}
local ORDER = {}

local function def(id, title, when, run)
  COMMANDS[id] = { title = title, when = when, run = run }
  ORDER[#ORDER + 1] = id
end

local function cmd(name, args)
  return function(buf)
    vim.api.nvim_buf_call(buf, function()
      require('perforated.commands').dispatch(name, { fargs = args or {}, bang = false })
    end)
  end
end

local function opened(st)
  return st.rec and st.rec.action ~= nil
end

local function in_depot(st)
  return st.rec and st.rec.depotFile ~= nil
end

local function hunk_at(st, line)
  for _, h in ipairs(st.hunks or {}) do
    local first = math.max(1, h.b_start)
    local last = h.b_count > 0 and (h.b_start + h.b_count - 1) or first
    if line >= first and line <= last then
      return h
    end
  end
end

def('checkout', 'Perforce: check out (open for edit)', function(st)
  return in_depot(st) and not opened(st)
end, function(buf)
  require('perforated.checkout').prompt(buf, 'edit')
end)
def('add', 'Perforce: open for add', function(st)
  return st.status == 'new'
end, cmd('add'))
def('get_latest', 'Perforce: get latest revision', function(st)
  return in_depot(st) and require('perforated.status').is_stale(st.rec)
end, cmd('sync', { '%' }))
def('resolve', 'Perforce: resolve', function(st)
  return opened(st) and st.rec.unresolved ~= nil
end, cmd('resolve', { '%' }))
def('diff', 'Perforce: diff against have revision', opened, cmd('diff'))
def('preview_hunk', 'Perforce: preview this change', function(st, line)
  return hunk_at(st, line) ~= nil
end, function(buf, line)
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    require('perforated.signs').preview()
  end)
end)
def('reset_hunk', 'Perforce: undo this change (reset hunk)', function(st, line)
  return hunk_at(st, line) ~= nil
end, function(buf, line)
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    require('perforated.signs').reset()
  end)
end)
def('reopen', 'Perforce: move to another changelist', opened, cmd('reopen'))
def('revert_unchanged', 'Perforce: revert if unchanged', function(st)
  return opened(st) and st.rec.action == 'edit'
end, function(buf)
  local st = require('perforated.buffer').get(buf)
  if st then
    require('perforated.checkout').revert(st.ws, { st.path }, true)
  end
end)
def('revert', 'Perforce: revert', opened, cmd('revert'))
def('describe_change', "Perforce: describe this file's changelist", function(st)
  return opened(st) and st.rec.change ~= 'default'
end, cmd('describe'))
def('line_change', 'Perforce: describe the changelist that last changed this line', function(st)
  return in_depot(st) and st.rec.action ~= 'add'
end, function(buf, line)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return
  end
  local spec = st.rec.action and require('perforated.p4').base_spec(st.rec)
    or (st.rec.depotFile .. '#' .. (st.rec.haveRev or 'head'))
  local b = require('perforated.views.base').base_line(st.hunks or {}, line)
  if not b then
    return vim.notify('[perforated] this line was changed locally (not submitted)')
  end
  require('perforated.history').annotate(st.ws, spec, {}, function(ann)
    local cl = ann and ann.cls[b]
    if cl then
      require('perforated.views.describe').open(st.ws, cl)
    end
  end)
end)
def('history', 'Perforce: file history', in_depot, cmd('filelog'))
def('annotate', 'Perforce: annotate', in_depot, cmd('annotate'))
def('timelapse', 'Perforce: time-lapse', in_depot, cmd('timelapse'))

--- Code actions for a buffer and 1-based line.
---@param buf integer
---@param line integer
---@return table[]  LSP Command objects
function M.actions(buf, line)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return {}
  end
  local out = {}
  for _, id in ipairs(ORDER) do
    local c = COMMANDS[id]
    if c.when(st, line) then
      out[#out + 1] = {
        title = c.title,
        kind = 'source',
        command = { title = c.title, command = 'perforated.' .. id, arguments = { buf, line } },
      }
    end
  end
  return out
end

local function execute(command, arguments)
  local id = command:match('^perforated%.(.+)$')
  local c = id and COMMANDS[id]
  if c and arguments then
    c.run(arguments[1], arguments[2])
  end
end

-- Client-side command handlers (vim.lsp.commands): no server round trip.
for _, id in ipairs(ORDER) do
  vim.lsp.commands['perforated.' .. id] = function(command)
    execute(command.command, command.arguments)
  end
end

--- The in-process server.
local function server(dispatchers)
  local closing = false
  local srv = {}
  local next_id = 0
  function srv.request(method, params, handler)
    next_id = next_id + 1
    local function callback(err, result) -- answer on the next tick, like a real server
      vim.schedule(function()
        handler(err, result)
      end)
    end
    if method == 'initialize' then
      callback(nil, {
        capabilities = {
          codeActionProvider = { codeActionKinds = { 'source' } },
          executeCommandProvider = {
            commands = vim.tbl_map(function(id)
              return 'perforated.' .. id
            end, ORDER),
          },
          textDocumentSync = 0,
        },
        serverInfo = { name = NAME },
      })
    elseif method == 'textDocument/codeAction' then
      local buf = vim.uri_to_bufnr(params.textDocument.uri)
      callback(nil, M.actions(buf, params.range.start.line + 1))
    elseif method == 'workspace/executeCommand' then
      execute(params.command, params.arguments)
      callback(nil, nil)
    else
      callback(nil, nil) -- shutdown, and anything else we don't implement
    end
    return true, next_id
  end
  function srv.notify(method)
    if method == 'exit' then
      closing = true
      dispatchers.on_exit(0, 15)
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

--- Attach the server to a Perforce buffer (one client per workspace).
---@param buf integer
---@param ws perforated.Workspace
function M.attach(buf, ws)
  vim.lsp.start({
    name = NAME,
    cmd = server,
    root_dir = ws.anchor or ws.root,
  }, { bufnr = buf, silent = true })
end

M._commands = COMMANDS

return M
