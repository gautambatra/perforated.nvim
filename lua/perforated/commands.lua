--- `:P4 <sub>` dispatcher and completion. The single command table below also generates the
--- flat aliases (`:P4info`, …) defined in plugin/perforated.lua.
---
--- Each command declares a scope:
---   'none'        — needs no Perforce context (e.g. `log`)
---   'workspace'   — needs a workspace (client); refused outside one
---   'connection'  — needs only a server connection; uses the workspace when there is one,
---                   else the connection-only context (works outside workspaces)

local M = {}

---@class perforated.Command
---@field scope 'none'|'workspace'|'connection'
---@field desc string
---@field run fun(ctx: perforated.Workspace?, o: table, args: string[])
---@field complete (fun(arglead: string, args: string[]): string[])?

local function notify(msg, level)
  local dbg = package.loaded['perforated.core.debug']
  if dbg and (level or 0) >= vim.log.levels.WARN then
    dbg.log(level >= vim.log.levels.ERROR and 'error' or 'warn', 'commands', '%s', msg)
  end
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

local function echo_lines(chunks_list)
  vim.api.nvim_echo(chunks_list, true, {})
end

--- Split `-c CL` and file arguments; files default to the current buffer's file.
---@param args string[]
---@return string? cl, string[] files, table flags
local function parse_file_args(args)
  local cl, files, flags = nil, {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '-c' then
      cl = args[i + 1]
      i = i + 1
    elseif a:match('^%-%a$') then
      flags[a] = true
    else
      files[#files + 1] = vim.fn.fnamemodify(vim.fn.expand(a), ':p')
    end
    i = i + 1
  end
  if #files == 0 then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= '' and vim.bo.buftype == '' then
      files[1] = name
    end
  end
  return cl, files, flags
end

local function need_files(files)
  if #files == 0 then
    notify('no file (open a file or pass paths)', vim.log.levels.WARN)
    return false
  end
  return true
end

local function complete_files(arglead)
  return vim.fn.getcompletion(arglead, 'file')
end

---@type table<string, perforated.Command>
M.commands = {
  info = {
    scope = 'connection',
    desc = 'Show workspace, connection and server information',
    run = function(ctx)
      ---@cast ctx perforated.Workspace
      ctx:ensure_info(function(ws, err)
        local i = ws.info or {}
        local function row(label, value, hl)
          return { { ('%-11s'):format(label), 'Title' }, { tostring(value or '—') .. '\n', hl } }
        end
        local lines = {}
        local function add(r)
          vim.list_extend(lines, r)
        end
        if ws.mode == 'connection' then
          add(
            row(
              'Workspace',
              'none (connection only — not inside a Perforce workspace)',
              'Comment'
            )
          )
        else
          add(row('Workspace', ('%s  [%s]'):format(ws.key, ws.mode)))
        end
        add(row('Client', ws:client()))
        add(row('Root', i.clientRoot or ws.root))
        if i.clientStream then
          add(row('Stream', i.clientStream))
        end
        add(row('User', ws:user()))
        add(row('Server', (ws.settings and ws.settings.P4PORT) or i.serverAddress))
        add(row('Version', i.serverVersion))
        add(row('Case', i.caseHandling))
        add(
          row(
            'Connection',
            ws.conn.state .. (ws.conn.last_error and ('  (' .. ws.conn.last_error .. ')') or ''),
            ws.conn.state == 'online' and 'DiagnosticOk' or 'DiagnosticWarn'
          )
        )
        if ws.config_file then
          add(row('P4CONFIG', ws.config_file))
        end
        if err then
          add(row('Error', err, 'ErrorMsg'))
        end
        -- Drop the trailing newline of the last chunk.
        lines[#lines][1] = lines[#lines][1]:gsub('\n$', '')
        echo_lines(lines)
      end)
    end,
  },

  edit = {
    scope = 'workspace',
    desc = 'Open files for edit: :P4 edit [-c CL] [file…] (default: sticky CL or default)',
    complete = complete_files,
    run = function(ws, _, args)
      local cl, files = parse_file_args(args)
      if need_files(files) then
        require('perforated.checkout').edit(ws, files, cl or ws.sticky_cl)
      end
    end,
  },

  add = {
    scope = 'workspace',
    desc = 'Open files for add: :P4 add [-c CL] [file…]',
    complete = complete_files,
    run = function(ws, _, args)
      local cl, files = parse_file_args(args)
      if need_files(files) then
        require('perforated.checkout').add(ws, files, cl or ws.sticky_cl)
      end
    end,
  },

  revert = {
    scope = 'workspace',
    desc = 'Revert files: :P4 revert[!] [-a] [file…] (! = no confirmation, -a = only unchanged)',
    complete = complete_files,
    run = function(ws, o, args)
      local _, files, flags = parse_file_args(args)
      if not need_files(files) then
        return
      end
      local unchanged = flags['-a']
      if not unchanged and not o.bang then
        local what = #files == 1 and vim.fn.fnamemodify(files[1], ':~:.') or (#files .. ' files')
        local ok = vim.fn.confirm(
          ('Revert %s? Local changes will be lost.'):format(what),
          '&Revert\n&Cancel',
          2
        )
        if ok ~= 1 then
          return
        end
      end
      require('perforated.checkout').revert(ws, files, unchanged)
    end,
  },

  diff = {
    scope = 'workspace',
    desc = 'Diff the current file: :P4 diff[!] [#rev|@CL|@=shelf|prev] (! = $P4DIFF); -a = all opened',
    complete = function()
      return { '#have', '#head', 'prev', '-a' }
    end,
    run = function(ws, o, args)
      if args[1] == '-a' then
        return require('perforated.diff.tab').open_opened(ws)
      end
      require('perforated.diff.view').open(
        vim.api.nvim_get_current_buf(),
        args[1],
        { external = o.bang }
      )
    end,
  },

  opened = {
    scope = 'workspace',
    desc = 'Opened files, grouped by changelist, in the quickfix list',
    run = function(ws, o)
      local lists = require('perforated.lists')
      lists.opened_items(ws, function(items)
        require('perforated.ui.qf').set({
          title = 'P4 opened · ' .. (ws:client() or ws.key),
          kind = 'opened',
          items = items,
          open = not o.bang and nil or false,
          producer = function(cb)
            lists.opened_items(ws, cb)
          end,
        })
      end)
    end,
  },

  status = {
    scope = 'workspace',
    desc = 'Stale and unresolved opened files in the quickfix list',
    run = function(ws, o)
      local lists = require('perforated.lists')
      require('perforated.poll').refresh(ws, { notify = false })
      lists.status_items(ws, function(items)
        require('perforated.ui.qf').set({
          title = 'P4 status · ' .. (ws:client() or ws.key),
          kind = 'status',
          items = items,
          open = not o.bang and nil or false,
          producer = function(cb)
            lists.status_items(ws, cb)
          end,
        })
      end)
    end,
  },

  hunks = {
    scope = 'workspace',
    desc = 'Hunks of all opened files (quickfix), or of this file: :P4 hunks %  (location list)',
    run = function(ws, o, args)
      local lists = require('perforated.lists')
      if args[1] == '%' then
        local buf = vim.api.nvim_get_current_buf()
        require('perforated.ui.qf').set({
          title = 'P4 hunks · ' .. vim.fn.expand('%:~:.'),
          kind = 'hunks',
          items = lists.buffer_hunk_items(buf),
          loclist = true,
          open = not o.bang and nil or false,
        })
        return
      end
      lists.all_hunk_items(ws, function(items)
        require('perforated.ui.qf').set({
          title = 'P4 hunks · ' .. (ws:client() or ws.key),
          kind = 'hunks',
          items = items,
          open = not o.bang and nil or false,
          producer = function(cb)
            lists.all_hunk_items(ws, cb)
          end,
        })
      end)
    end,
  },

  view = {
    scope = 'workspace',
    desc = 'Client view: :P4 view [tab|float|split] (also plain :P4)',
    complete = function()
      return { 'tab', 'float', 'split' }
    end,
    run = function(ws, _, args)
      require('perforated.views.client').open(ws, { kind = args[1] })
    end,
  },

  change = {
    scope = 'workspace',
    desc = "Edit a changelist description: :P4 change[!] [N|new]  (! = full spec; no N = current file's CL); :P4 change -d N deletes a pending CL",
    complete = function()
      return { 'new', '-d' }
    end,
    run = function(ws, o, args)
      local editor = require('perforated.views.change_editor')
      if args[1] == '-d' then
        local st = require('perforated.buffer').get(0)
        local target = args[2] or (st and st.rec and st.rec.change)
        if not target then
          return notify('usage: :P4 change -d N', vim.log.levels.WARN)
        end
        return require('perforated.ops').delete_change(ws, target)
      end
      local cl = args[1]
      if cl == 'new' then
        return editor.new(ws)
      end
      if not cl then
        local st = require('perforated.buffer').get(0)
        cl = st and st.rec and st.rec.change
        if not cl then
          return notify('current file is not opened; pass a changelist number', vim.log.levels.WARN)
        end
      end
      if cl == 'default' then
        return editor.edit(ws, cl) -- explains why the default CL has no description
      end
      if o.bang then
        return editor.full(ws, cl)
      end
      -- Pending or submitted is decided by the server.
      require('perforated.changelists').change_status(ws, cl, function(status)
        editor.edit(ws, cl, { submitted = status == 'submitted' })
      end)
    end,
  },

  pick = {
    scope = 'workspace',
    desc = 'Picker: :P4 pick {pending|opened|submitted|users}',
    complete = function()
      return { 'pending', 'opened', 'submitted', 'users' }
    end,
    run = function(ws, _, args)
      local sources = require('perforated.picker.sources')
      local fn = sources[args[1] or 'pending']
      if not fn then
        return notify('unknown source: ' .. tostring(args[1]), vim.log.levels.WARN)
      end
      fn(ws)
    end,
  },

  changes = {
    scope = 'connection',
    desc = 'Submitted changelists: :P4 changes [-u user] [-m N] [path] (default: this client)',
    run = function(ws, _, args)
      local opts, i = {}, 1
      while i <= #args do
        if args[i] == '-u' then
          opts.user = args[i + 1]
          i = i + 1
        elseif args[i] == '-m' then
          opts.max = tonumber(args[i + 1])
          i = i + 1
        else
          opts.path = args[i]
        end
        i = i + 1
      end
      if ws.mode == 'connection' and not opts.path then
        opts.path = '//...'
      end
      require('perforated.views.changes').open(ws, opts)
    end,
  },

  describe = {
    scope = 'connection',
    desc = "Describe a changelist: :P4 describe [N|default]  (no N = the current file's CL)",
    run = function(ws, _, args)
      local cl = args[1]
      if not cl then
        local st = require('perforated.buffer').get(0)
        cl = st and st.rec and st.rec.change
        if not cl then
          return notify('current file is not opened; pass a changelist number', vim.log.levels.WARN)
        end
      end
      if cl ~= 'default' and not cl:match('^%d+$') then
        return notify('not a changelist number: ' .. cl, vim.log.levels.ERROR)
      end
      require('perforated.views.describe').open(ws, cl)
    end,
  },

  filelog = {
    scope = 'connection',
    desc = 'File history: :P4 filelog [file|//depot/path|dir]  (default: current file; a directory lists its changelists)',
    complete = complete_files,
    run = function(ws, _, args)
      local h = require('perforated.views.history')
      if not args[1] then
        return h.open_buf(0)
      end
      local path = args[1]
      if not path:match('^//') then
        path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
      end
      h.open(ws, path)
    end,
  },

  history = {
    scope = 'connection',
    desc = 'Alias of :P4 filelog',
    complete = complete_files,
    run = function(ws, o, args)
      M.commands.filelog.run(ws, o, args)
    end,
  },

  timelapse = {
    scope = 'connection',
    desc = 'Time-lapse: step through every revision of the current file (or a depot path)',
    run = function(ws, _, args)
      local tl = require('perforated.views.timelapse')
      if args[1] then
        local path = args[1]
        if not path:match('^//') then
          path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
        end
        return tl.open(ws, path)
      end
      tl.open_buf(0)
    end,
  },

  annotate = {
    scope = 'connection',
    desc = 'Annotate the current file (or a depot revision): :P4 annotate [//depot/path#rev]',
    run = function(ws, _, args)
      local a = require('perforated.views.annotate')
      if args[1] and args[1]:match('^//') then
        local spec = args[1]
        if not spec:match('[#@]') then
          spec = spec .. '#head'
        end
        return a.open_spec(ws, spec)
      end
      a.open_buf(0)
    end,
  },

  blame = {
    scope = 'none',
    desc = 'Current-line blame (virtual text): :P4 blame [on|off]  (no args: toggle)',
    complete = function()
      return { 'on', 'off' }
    end,
    run = function(_, _, args)
      local on = require('perforated.blame').set(({ on = true, off = false })[args[1]])
      notify('current-line blame ' .. (on and 'on' or 'off'))
    end,
  },

  lookup = {
    scope = 'connection',
    desc = 'Go to a changelist (number), a file or directory history (path) or a user: :P4 lookup [what]',
    run = function(ws, _, args)
      require('perforated.lookup').run(ws, args[1])
    end,
  },

  shelve = {
    scope = 'workspace',
    desc = "Shelve: :P4 shelve [-c CL] [file…]  (default: the current file's CL, all its files; -d deletes the shelf)",
    complete = complete_files,
    run = function(ws, _, args)
      local ops = require('perforated.ops')
      local cl, files, flags = parse_file_args(args)
      local explicit = #vim.tbl_filter(function(a)
        return not a:match('^%-') and a ~= cl
      end, args) > 0
      local st = require('perforated.buffer').get(0)
      cl = cl or (st and st.rec and st.rec.change)
      if not cl then
        return notify('pass -c CL (the current file is not opened)', vim.log.levels.WARN)
      end
      if flags['-d'] then
        return ops.delete_shelved(ws, cl, nil)
      end
      ops.shelve(ws, cl, explicit and files or nil)
    end,
  },

  unshelve = {
    scope = 'workspace',
    desc = 'Unshelve: :P4 unshelve CL [-c target] [//depot/file…]',
    run = function(ws, _, args)
      local shelf, target, files = nil, nil, {}
      local i = 1
      while i <= #args do
        if args[i] == '-c' then
          target = args[i + 1]
          i = i + 1
        elseif not shelf and args[i]:match('^%d+$') then
          shelf = args[i]
        else
          files[#files + 1] = args[i]
        end
        i = i + 1
      end
      if not shelf then
        return notify('usage: :P4 unshelve CL [-c target] [files]', vim.log.levels.WARN)
      end
      require('perforated.ops').unshelve(ws, shelf, #files > 0 and files or nil, target)
    end,
  },

  submit = {
    scope = 'workspace',
    desc = "Submit a changelist (with a confirmation): :P4 submit [CL|default]  (default: the current file's CL)",
    run = function(ws, _, args)
      local cl = args[1]
      if not cl then
        local st = require('perforated.buffer').get(0)
        cl = st and st.rec and st.rec.change
        if not cl then
          return notify('current file is not opened; pass a changelist number', vim.log.levels.WARN)
        end
      end
      require('perforated.ops').submit(ws, cl)
    end,
  },

  sync = {
    scope = 'workspace',
    desc = 'Sync the whole workspace (:P4 sync), or get the latest revision of files (:P4 sync %|path …); @CL / #head for a revision',
    complete = complete_files,
    run = function(ws, _, args)
      if #args == 1 and args[1] == '@' then
        return require('perforated.ops').pick_sync_change(ws) -- pick a changelist
      end
      local out = {}
      for _, a in ipairs(args) do
        if a:match('^[@#]') then
          out[#out + 1] = '//' .. (ws:client() or '') .. '/...' .. a -- a revision for the workspace
        elseif a:match('^//') then
          out[#out + 1] = a
        else
          local path, rev = a:match('^(.-)([#@].*)$')
          path = path or a
          out[#out + 1] = vim.fn.fnamemodify(vim.fn.expand(path), ':p') .. (rev or '')
        end
      end
      require('perforated.ops').sync(ws, out)
    end,
  },

  resolve = {
    scope = 'workspace',
    desc = 'Resolve: :P4 resolve [file…]  (-am first, then $P4MERGE for conflicts; no args: all files)',
    complete = complete_files,
    run = function(ws, _, args)
      local files = {}
      for _, a in ipairs(args) do
        files[#files + 1] = vim.fn.fnamemodify(vim.fn.expand(a), ':p')
      end
      require('perforated.resolve').run(ws, #files > 0 and files or nil)
    end,
  },

  delete = {
    scope = 'workspace',
    desc = 'Open files for delete (with a confirmation): :P4 delete [file…]',
    complete = complete_files,
    run = function(ws, _, args)
      local _, files = parse_file_args(args)
      if need_files(files) then
        require('perforated.ops').delete(ws, files)
      end
    end,
  },

  move = {
    scope = 'workspace',
    desc = 'Move/rename the current file: :P4 move {new path}',
    complete = complete_files,
    run = function(_, _, args)
      if not args[1] then
        return notify('usage: :P4 move {new path}', vim.log.levels.WARN)
      end
      require('perforated.ops').move(vim.api.nvim_get_current_buf(), args[1])
    end,
  },

  integrate = {
    scope = 'workspace',
    desc = 'Cherry-pick a submitted changelist: :P4 integrate [CL]  (no CL: pick from a source path)',
    run = function(ws, _, args)
      require('perforated.integrate').run(ws, args[1])
    end,
  },

  jobs = {
    scope = 'none',
    desc = 'Running p4 jobs (sync, submit), live; x in the list stops one',
    run = function()
      require('perforated.jobs').show()
    end,
  },

  cancel = {
    scope = 'none',
    desc = 'Stop every running p4 job (sync, submit)',
    run = function()
      require('perforated.jobs').cancel()
    end,
  },

  notifications = {
    scope = 'none',
    desc = 'Show recent notifications (stale files, …)',
    run = function()
      require('perforated.ui.toast').open_history()
    end,
  },

  dismiss = {
    scope = 'none',
    desc = 'Dismiss visible notifications',
    run = function()
      require('perforated.ui.toast').dismiss()
    end,
  },

  debug = {
    scope = 'none',
    desc = 'Debug log: :P4 debug [on [level]|off|open|clear|snapshot]  (no args: status)',
    complete = function()
      return { 'on', 'off', 'open', 'clear', 'snapshot', 'trace', 'debug', 'info' }
    end,
    run = function(_, _, args)
      local dbg = require('perforated.core.debug')
      local sub = args[1]
      if sub == 'on' then
        dbg.enable({ level = args[2] }, 'enabled by :P4 debug on')
        notify('debug log on → ' .. dbg.file())
      elseif sub == 'off' then
        dbg.disable()
        notify('debug log off')
      elseif sub == 'open' then
        dbg.open()
      elseif sub == 'clear' then
        dbg.clear()
        notify('debug log cleared')
      elseif sub == 'snapshot' then
        dbg.snapshot()
        notify('snapshot written to ' .. dbg.file())
      elseif sub == nil then
        notify(
          dbg.enabled and ('debug log on → ' .. dbg.file())
            or ('debug log off (would write to ' .. (dbg.file() or dbg.default_file()) .. ')')
        )
      else
        notify('usage: :P4 debug [on [level]|off|open|clear|snapshot]', vim.log.levels.WARN)
      end
    end,
  },

  log = {
    scope = 'none',
    desc = 'Show the log of p4 commands run by the plugin (with timings)',
    run = function()
      require('perforated.core.log').open()
    end,
  },

  login = {
    scope = 'connection',
    desc = 'Log in to the Perforce server (password prompt)',
    run = function(ctx)
      ---@cast ctx perforated.Workspace
      ctx.conn:login(function(ok)
        if ok then
          notify('logged in')
        end
      end)
    end,
  },

  refresh = {
    scope = 'connection',
    desc = 'Refresh cached state (! also forgets workspace detection and settings)',
    run = function(ctx, o)
      ---@cast ctx perforated.Workspace
      if o.bang then
        require('perforated.core.activation').reset()
        require('perforated.core.env').reset()
      end
      ctx.fstat = {}
      ctx.clmemo = {}
      ctx.info, ctx.settings = nil, nil
      local function reinfo()
        ctx:ensure_info(function(_, err)
          if err then
            notify('refresh: ' .. err, vim.log.levels.WARN)
          end
        end)
      end
      if ctx.conn.state == 'offline' then
        ctx.conn:probe(function(ok)
          if ok then
            reinfo()
          end
        end)
      else
        reinfo()
      end
    end,
  },
}

--- Sorted subcommand names.
---@return string[]
function M.names()
  local out = vim.tbl_keys(M.commands)
  table.sort(out)
  return out
end

--- Resolve the context for a command scope and call `cb(ctx)`; reports refusals itself.
---@param scope 'none'|'workspace'|'connection'
---@param cb fun(ctx: perforated.Workspace?)
function M.resolve(scope, cb)
  if scope == 'none' then
    return cb(nil)
  end
  if not require('perforated.core.env').p4_bin() then
    return notify('p4 executable not found (see :checkhealth perforated)', vim.log.levels.ERROR)
  end
  local workspace = require('perforated.core.workspace')
  local ws = workspace.for_buf()
  if ws then
    return cb(ws)
  end
  local name = vim.api.nvim_buf_get_name(0)
  local dir
  if vim.bo.buftype == '' and name ~= '' and not name:find('^%a[%w+.-]*://') then
    dir = vim.fs.dirname(name)
  else
    dir = workspace.normalize(vim.uv.cwd() or '.')
  end
  require('perforated.core.activation').resolve(dir, function(found)
    if found then
      return cb(found)
    end
    if scope == 'connection' then
      return cb(workspace.connection())
    end
    notify('not in a Perforce workspace (see :checkhealth perforated)', vim.log.levels.WARN)
  end)
end

--- Run a subcommand by name.
---@param name string
---@param o table user-command opts (fargs = arguments after the subcommand)
function M.dispatch(name, o)
  local cmd = M.commands[name]
  if not cmd then
    return notify(('unknown command: %s (try :P4 <Tab>)'):format(name), vim.log.levels.ERROR)
  end
  local args = o.fargs or {}
  M.resolve(cmd.scope, function(ctx)
    cmd.run(ctx, o, args)
  end)
end

--- Entry point for `:P4 …`.
---@param o table
function M.run(o)
  local fargs = vim.deepcopy(o.fargs or {})
  local name = table.remove(fargs, 1)
  if not name then
    name = 'view' -- plain :P4 opens the client view
  end
  local bang = o.bang
  if name:sub(-1) == '!' then -- `:P4 revert!` reads naturally; `:P4! revert` works too
    name, bang = name:sub(1, -2), true
  end
  M.dispatch(name, vim.tbl_extend('force', o, { fargs = fargs, bang = bang }))
end

--- Completion for `:P4 …`.
function M.complete(arglead, cmdline, _)
  local rest = cmdline:gsub('^%s*%S+%s*', '')
  local words = vim.split(rest, '%s+', { trimempty = false })
  if #words <= 1 then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, M.names())
  end
  return M.complete_args(words[1], arglead, cmdline)
end

--- Argument completion for a given subcommand (also used by the flat aliases).
function M.complete_args(name, arglead, _)
  local cmd = M.commands[name]
  if cmd and cmd.complete then
    return vim.tbl_filter(function(c)
      return vim.startswith(c, arglead)
    end, cmd.complete(arglead, {}))
  end
  return {}
end

return M
