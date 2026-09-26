--- Per-workspace connection state machine.
---
---   unknown ──ok──▶ online
---      │              │ connect failure / timeout
---      ▼              ▼
---   offline ◀───── (backoff probes: `p4 -ztag info -s`, 5s → 5min) ──ok──▶ online
---   auth_needed ── password prompt (once) ──ok──▶ online
---                                        └─cancel/fail──▶ offline_auth (fail fast; :P4 login)

local events = require('perforated.core.events')

local M = {}

M.AUTH_PATTERNS = {
  'P4PASSWD%) invalid or unset',
  'session has expired',
  'Your session was logged out',
  'please login again',
  'Password invalid',
  'Password must be set before access can be granted',
}

M.CONNECT_PATTERNS = {
  'Connect to server failed',
  'TCP connect to',
  'SSL connect to',
  'check %$P4PORT',
  'Partner exited unexpectedly',
  'RpcTransport: partial message read',
  'Connection refused',
  'Name or service not known',
}

local BACKOFF_MIN, BACKOFF_MAX = 5000, 300000

---@param res perforated.RunResult
---@return 'ok'|'auth'|'connect'|'error'
function M.classify(res)
  local function any(patterns, texts)
    for _, t in ipairs(texts) do
      for _, p in ipairs(patterns) do
        if t:find(p) then
          return true
        end
      end
    end
    return false
  end
  local texts = vim.list_extend({ res.stderr or '' }, res.errors or {})
  if any(M.AUTH_PATTERNS, texts) then
    return 'auth'
  end
  if res.timed_out or (res.code ~= 0 and any(M.CONNECT_PATTERNS, texts)) then
    return 'connect'
  end
  if res.ok then
    return 'ok'
  end
  return 'error'
end

---@class perforated.Conn
---@field state 'unknown'|'online'|'offline'|'auth_needed'|'offline_auth'
---@field ws perforated.Workspace
---@field backoff integer
---@field timer uv.uv_timer_t?
---@field auth_waiters fun()[]   jobs to retry after a successful login
---@field last_error string?
---@field epoch integer          bumped on every successful login
---@field login_pending boolean? a login (prompt + p4 login) is in progress
local Conn = {}
Conn.__index = Conn

---@param ws perforated.Workspace
---@return perforated.Conn
function M.new(ws)
  return setmetatable(
    { state = 'unknown', ws = ws, backoff = BACKOFF_MIN, auth_waiters = {}, epoch = 0 },
    Conn
  )
end

function Conn:_set(state, err)
  if self.state == state and self.last_error == err then
    return
  end
  require('perforated.core.debug').log(
    state == 'online' and 'info' or 'warn',
    'conn',
    '%s: %s -> %s%s',
    self.ws.key,
    self.state,
    state,
    err and (' (' .. err .. ')') or ''
  )
  self.state = state
  self.last_error = err
  events.emit('Status', { ws = self.ws.key, conn = state })
  local status = package.loaded['perforated.status']
  if status then
    status.update_ws(self.ws)
  end
end

--- Should a (non-probe) call be refused immediately?
---@return string? reason
function Conn:refuse()
  if self.state == 'offline' then
    return 'Perforce server unreachable (offline); retrying in background'
  elseif self.state == 'offline_auth' then
    return 'Not logged in to Perforce; run :P4 login'
  end
end

--- Feed a result; returns the classification.
---@param res perforated.RunResult
---@return 'ok'|'auth'|'connect'|'error'
function Conn:observe(res)
  local kind = M.classify(res)
  if kind == 'ok' or kind == 'error' then
    -- A server-side error still proves the server is reachable and we're authenticated.
    -- Not while a login is in progress: only the login decides that (some commands, like
    -- `p4 info`, succeed without one).
    if self.state ~= 'online' and not self.login_pending then
      self:_stop_timer()
      self.backoff = BACKOFF_MIN
      self:_set('online')
    end
  elseif kind == 'connect' then
    if self.state ~= 'offline' then
      self:_set('offline', res.errors[1] or vim.trim(res.stderr or ''))
      self:_schedule_probe()
    end
  end
  return kind
end

function Conn:_stop_timer()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
end

function Conn:_schedule_probe()
  self:_stop_timer()
  local delay = self.backoff
  self.backoff = math.min(self.backoff * 2, BACKOFF_MAX)
  require('perforated.core.debug').log(
    'debug',
    'conn',
    '%s: next probe in %dms',
    self.ws.key,
    delay
  )
  self.timer = vim.uv.new_timer()
  self.timer:start(delay, 0, function()
    vim.schedule(function()
      self:probe()
    end)
  end)
end

--- Probe the server now (also used by :P4 refresh while offline).
---@param cb fun(ok: boolean)?
function Conn:probe(cb)
  self.ws:run({ 'info', '-s' }, {
    probe = true,
    priority = 3,
    timeout = require('perforated.config').get().runner.background_timeout,
  }, function(res)
    local kind = M.classify(res)
    if kind == 'connect' then
      self:_schedule_probe()
    end
    if cb then
      cb(kind == 'ok' or kind == 'error')
    end
  end)
end

--- Start the login flow once; `retry` is re-run after a successful login (or called with
--- nil-result semantics by the caller on failure). Queue for this workspace is paused
--- meanwhile so nothing else hits the server unauthenticated.
---@param retry fun(ok: boolean)
function Conn:need_auth(retry)
  self.auth_waiters[#self.auth_waiters + 1] = retry
  -- One login at a time. The state alone isn't enough: another call can succeed while the
  -- prompt is up (e.g. `p4 info` needs no login) and set it back to 'online'.
  if self.login_pending then
    return
  end
  self.login_pending = true
  self:_set('auth_needed')
  local queue = require('perforated.core.queue').global()
  queue:pause(self.ws.key)
  vim.schedule(function()
    self:login(function(ok)
      self.login_pending = false
      queue:resume(self.ws.key)
      local waiters = self.auth_waiters
      self.auth_waiters = {}
      for _, w in ipairs(waiters) do
        w(ok)
      end
    end)
  end)
end

--- Prompt for a password (inputsecret) and run `p4 login` with it on stdin.
---@param cb fun(ok: boolean)
function Conn:login(cb)
  local user = self.ws.settings and self.ws.settings.P4USER or ''
  local prompt = ('Perforce password%s: '):format(user ~= '' and (' for ' .. user) or '')
  local ok_input, pw = pcall(vim.fn.inputsecret, prompt)
  if not ok_input or pw == nil or pw == '' then
    self:_set('offline_auth', 'login cancelled')
    return cb(false)
  end
  self.ws:run(
    { 'login' },
    { probe = true, force = true, stdin = pw, priority = 1, no_auth_retry = true },
    function(res)
      if res.ok then
        self.epoch = self.epoch + 1
        self:_set('online')
        cb(true)
      else
        local msg = res.errors[1] or vim.trim(res.stderr)
        self:_set('offline_auth', msg)
        vim.notify('[perforated] login failed: ' .. msg, vim.log.levels.ERROR)
        cb(false)
      end
    end
  )
end

function Conn:dispose()
  self:_stop_timer()
end

return M
