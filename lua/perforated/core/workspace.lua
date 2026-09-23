--- Workspace registry.
---
--- Exactly one Workspace object exists per workspace (keyed by its anchor); all buffers of
--- that workspace reference it and share its connection state, info, caches, sticky CL and
--- queue group. Buffers keep only a reference (`vim.b.perforated_ws`) plus per-buffer data.
---
--- Anchor = directory containing the P4CONFIG file that was found, or the client root for
--- environment-only setups. Every p4 call for the workspace runs with cwd = PWD = anchor.
---
--- A special "connection" context (no client) serves connection-only commands outside any
--- workspace (describe, changes, filelog of depot paths, …); it runs from Neovim's cwd.

local runner = require('perforated.core.runner')
local queue = require('perforated.core.queue')
local conn = require('perforated.core.conn')
local parse = require('perforated.core.parse')
local events = require('perforated.core.events')
local dbg = require('perforated.core.debug')

local M = {}

M.CONNECTION_KEY = '<connection>'

---@class perforated.Workspace
---@field key string
---@field anchor string?          nil for the connection context
---@field config_file string?     P4CONFIG file path (config mode)
---@field mode 'config'|'env'|'connection'
---@field info table?             `p4 -ztag info` record
---@field settings table<string,string>?  `p4 set -q` values (local, no server call)
---@field root string?            client root (normalised, no trailing slash)
---@field icase boolean           server is case-insensitive
---@field conn perforated.Conn
---@field buffers table<integer, true>
---@field fstat table<string, table>      path → fstat record
---@field clmemo table<string, table>     change → { user, client, time, desc }
---@field sticky_cl string?
---@field idle boolean
local Workspace = {}
Workspace.__index = Workspace

local registry = {} ---@type table<string, perforated.Workspace>
local buf_ws = {} ---@type table<integer, string>
local augroup ---@type integer?

local function normalize(path)
  path = vim.fs.normalize(path)
  if #path > 1 then
    path = path:gsub('/+$', '')
  end
  return path
end
M.normalize = normalize

---@param root string
---@param path string
---@param icase boolean?
---@return boolean
function M.is_under(root, path, icase)
  if icase then
    root, path = root:lower(), path:lower()
  end
  return path == root or (path:sub(1, #root + 1) == root .. '/') or root == '/'
end

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup('perforated.workspace', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = augroup,
    callback = function(ev)
      M.detach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('DirChanged', {
    group = augroup,
    callback = function()
      for _, ws in pairs(registry) do
        ws:_maybe_idle()
      end
    end,
  })
end

---@param spec { key: string, anchor: string?, config_file: string?, mode: string, root: string? }
---@return perforated.Workspace
function M.get_or_create(spec)
  local ws = registry[spec.key]
  if ws then
    return ws
  end
  ws = setmetatable({
    key = spec.key,
    anchor = spec.anchor and normalize(spec.anchor) or nil,
    config_file = spec.config_file,
    mode = spec.mode,
    root = spec.root and normalize(spec.root) or nil,
    icase = false,
    buffers = {},
    fstat = {},
    clmemo = {},
    idle = false,
  }, Workspace)
  ws.conn = conn.new(ws)
  registry[spec.key] = ws
  dbg.info(
    'workspace',
    'created %s mode=%s anchor=%s config=%s',
    spec.key,
    spec.mode,
    tostring(ws.anchor),
    tostring(spec.config_file)
  )
  if spec.mode ~= 'connection' then
    ensure_autocmds()
    events.emit('WorkspaceActivated', { ws = ws.key })
  end
  return ws
end

--- The connection-only context (no client), created on first use.
---@return perforated.Workspace
function M.connection()
  return M.get_or_create({ key = M.CONNECTION_KEY, mode = 'connection' })
end

---@return string
function Workspace:cwd()
  return self.anchor or normalize(vim.uv.cwd() or '.')
end

---@param reason string
---@return perforated.RunResult
local function refused(reason)
  return {
    ok = false,
    code = -1,
    signal = 0,
    records = {},
    warnings = {},
    errors = { reason },
    stderr = '',
    ms = 0,
    timed_out = false,
    argv = {},
    refused = true,
  }
end

---@class perforated.RunOpts
---@field priority integer?      1 interactive (default), 2 buffer, 3 background
---@field key string?            de-duplication key (scoped to the workspace)
---@field tagged boolean?
---@field stdin string|string[]?
---@field timeout integer?       ms; 0 = none; default from config (interactive/background)
---@field env_mode ('internal'|'user')?
---@field globals string[]?
---@field probe boolean?         bypass the offline fail-fast gate
---@field force boolean?         bypass a paused queue group (login)
---@field no_auth_retry boolean?
---@field cwd string?           override the working directory (connection context only)

--- Run a p4 command for this workspace through the shared queue.
---@param args string[]
---@param opts perforated.RunOpts?
---@param cb fun(res: perforated.RunResult)
function Workspace:run(args, opts, cb)
  opts = opts or {}
  if not opts.probe then
    local reason = self.conn:refuse()
    if reason then
      vim.schedule(function()
        cb(refused(reason))
      end)
      return
    end
  end
  local rcfg = require('perforated.config').get().runner
  local timeout = opts.timeout
  if timeout == nil then
    timeout = (opts.priority or 1) >= queue.PRIORITY.background and rcfg.background_timeout
      or rcfg.timeout
  end
  queue.global():push({
    group = self.key,
    priority = opts.priority,
    key = opts.key and (self.key .. '|' .. opts.key) or nil,
    force = opts.force,
    start = function(done)
      runner.run({
        args = args,
        cwd = (self.mode == 'connection' and opts.cwd) or self:cwd(),
        globals = opts.globals,
        tagged = opts.tagged,
        stdin = opts.stdin,
        timeout = timeout,
        env_mode = opts.env_mode,
        ws = self.key,
      }, done)
    end,
    cb = function(res)
      local kind = self.conn:observe(res)
      if kind == 'auth' and not opts.no_auth_retry then
        self.conn:need_auth(function(ok)
          if ok then
            self:run(args, vim.tbl_extend('force', opts, { no_auth_retry = true }), cb)
          else
            cb(res)
          end
        end)
        return
      end
      cb(res)
    end,
  })
end

--- Fetch (once) `p4 set -q` and `p4 -ztag info`. Concurrent callers share the calls.
---@param cb fun(ws: perforated.Workspace, err: string?)
---@param priority integer?
function Workspace:ensure_info(cb, priority)
  if self.info and self.settings then
    return cb(self)
  end
  local pending = 2
  local err
  local function done()
    pending = pending - 1
    if pending == 0 then
      cb(self, err)
    end
  end
  if self.settings then
    done()
  else
    -- `p4 set` is local and launches nothing, so it runs with the user's real environment
    -- (the internal environment would report our neutralised P4DIFF/P4MERGE values).
    local opts =
      { tagged = false, key = 'set', probe = true, priority = priority, env_mode = 'user' }
    self:run({ 'set', '-q' }, opts, function(res)
      if res.ok and res.stdout then
        local s = {}
        for name, v in pairs(parse.p4set(res.stdout)) do
          s[name] = v.value
        end
        self.settings = s
      end
      done()
    end)
  end
  if self.info then
    return done()
  end
  self:run({ 'info' }, { key = 'info', priority = priority }, function(res)
    local rec = res.ok and res.records[1]
    if rec then
      self:_set_info(rec)
    else
      err = res.errors[1] or vim.trim(res.stderr)
    end
    done()
  end)
end

---@param rec table
function Workspace:_set_info(rec)
  dbg.info(
    'workspace',
    '%s info: client=%s root=%s user=%s server=%s case=%s stream=%s',
    self.key,
    tostring(rec.clientName),
    tostring(rec.clientRoot),
    tostring(rec.userName),
    tostring(rec.serverVersion),
    tostring(rec.caseHandling),
    tostring(rec.clientStream)
  )
  self.info = rec
  local icase = rec.caseHandling == 'insensitive'
  if icase ~= self.icase then
    -- Keys are case-folded on case-insensitive servers (the macOS default). Buffers attached
    -- before `p4 info` answered carry unfolded keys: recompute them.
    self.icase = icase
    self.fstat = {}
    local buffer = package.loaded['perforated.buffer']
    if buffer then
      buffer.rekey(self)
    end
  end
  if rec.clientRoot and rec.clientName and rec.clientName ~= '*unknown*' then
    self.root = normalize(rec.clientRoot)
  end
  events.emit('Status', { ws = self.key })
end

--- Identity of the server, for caches shared across workspaces of one session.
---@return string
function Workspace:server_key()
  return (self.settings and self.settings.P4PORT)
    or (self.info and self.info.serverAddress)
    or self.key
end

---@return string?
function Workspace:client()
  local info = self.info
  if info and info.clientName and info.clientName ~= '*unknown*' then
    return info.clientName
  end
  return self.settings and self.settings.P4CLIENT
end

---@return string?
function Workspace:user()
  local info = self.info
  if info and info.userName and info.userName ~= '*unknown*' then
    return info.userName
  end
  return self.settings and self.settings.P4USER
end

---@param buf integer
function Workspace:attach(buf)
  self.buffers[buf] = true
  self.idle = false
  buf_ws[buf] = self.key
  vim.b[buf].perforated_ws = self.key
end

--- Free heavy state when no buffer uses the workspace and cwd is outside it. The object
--- (and cheap state such as the sticky CL) stays registered and reactivates on demand.
function Workspace:_maybe_idle()
  if self.mode == 'connection' or self.idle or next(self.buffers) then
    return
  end
  local cwd = normalize(vim.uv.cwd() or '/')
  for _, root in ipairs({ self.anchor, self.root }) do
    if root and M.is_under(root, cwd, self.icase) then
      return
    end
  end
  self.idle = true
  dbg.info('workspace', '%s idle (no buffers, cwd outside)', self.key)
  self.conn:dispose()
  self.fstat = {}
  self.clmemo = {}
  events.emit('WorkspaceIdle', { ws = self.key })
end

---@param buf integer
function M.detach(buf)
  local key = buf_ws[buf]
  if not key then
    return
  end
  buf_ws[buf] = nil
  local ws = registry[key]
  if ws then
    ws.buffers[buf] = nil
    ws:_maybe_idle()
  end
end

---@param buf integer?
---@return perforated.Workspace?
function M.for_buf(buf)
  local key = buf_ws[buf or vim.api.nvim_get_current_buf()]
  return key and registry[key] or nil
end

---@param key string
---@return perforated.Workspace?
function M.get(key)
  return registry[key]
end

--- All workspaces (excluding the connection context), sorted by key.
---@return perforated.Workspace[]
function M.list()
  local out = {}
  for key, ws in pairs(registry) do
    if key ~= M.CONNECTION_KEY then
      out[#out + 1] = ws
    end
  end
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

--- Workspace for the current buffer, else for Neovim's cwd (resolved via the activation
--- gate, which may create it). Returns nil outside any workspace.
---@return perforated.Workspace?
function M.current()
  local ws = M.for_buf()
  if ws then
    return ws
  end
  return require('perforated.core.activation').for_dir(normalize(vim.uv.cwd() or '.'))
end

--- Test helper.
function M._reset()
  for _, ws in pairs(registry) do
    ws.conn:dispose()
  end
  registry, buf_ws = {}, {}
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
end

return M
