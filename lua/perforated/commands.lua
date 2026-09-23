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
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

local function echo_lines(chunks_list)
  vim.api.nvim_echo(chunks_list, true, {})
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
    -- The client view arrives in M2; until then `:P4` shows info.
    name = 'info'
  end
  M.dispatch(name, vim.tbl_extend('force', o, { fargs = fargs }))
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
    return cmd.complete(arglead, {})
  end
  return {}
end

return M
