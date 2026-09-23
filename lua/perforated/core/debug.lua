--- Debug mode: diagnostic messages to a log file, for investigating issues on a live machine.
---
--- Enable with any of:
---   config        `debug = { enabled = true, level = 'debug' }`
---   environment   `PERFORATED_DEBUG=1` (or `=trace` / `=info` …) — no config change needed
---   runtime       `:P4 debug on`
---
--- Cheap when off: `log()` is a boolean check; callers guard expensive messages with
--- `if dbg.enabled then`. When on, lines are buffered and appended every 250 ms (errors are
--- flushed immediately). One file is shared by all Neovim sessions; every line carries the
--- session's pid. The file rotates to `<file>.1` above `debug.max_kb`.
---
--- Secrets never reach the file: `p4 login` stdin and P4PASSWD are redacted.

local M = {}

M.LEVELS = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
local NAMES = { 'ERROR', 'WARN', 'INFO', 'DEBUG', 'TRACE' }

M.enabled = false
local level = M.LEVELS.debug
local path ---@type string?
local max_bytes = 5 * 1024 * 1024
local pending = {} ---@type string[]
local timer ---@type uv.uv_timer_t?
local pid = vim.uv.os_getpid()

--- Default log file path.
---@return string
function M.default_file()
  return vim.fs.joinpath(vim.fn.stdpath('log') --[[@as string]], 'perforated.log')
end

---@return string?
function M.file()
  return path
end

local function rotate()
  local st = path and vim.uv.fs_stat(path)
  if st and st.size > max_bytes then
    vim.uv.fs_rename(path, path .. '.1')
  end
end

--- Append buffered lines to the file (safe from fast/luv callbacks: plain Lua io).
function M.flush()
  if #pending == 0 or not path then
    return
  end
  local lines = pending
  pending = {}
  rotate()
  local fd = io.open(path, 'a')
  if not fd then
    return
  end
  fd:write(table.concat(lines, '\n'), '\n')
  fd:close()
end

local function ensure_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(250, 250, function()
    M.flush()
  end)
  -- Don't let the flush timer keep a headless Neovim alive.
  timer:unref()
end

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

---@param lvl integer
---@param scope string
---@param msg string
local function push(lvl, scope, msg)
  local sec, usec = vim.uv.gettimeofday()
  local ts = os.date('%Y-%m-%dT%H:%M:%S', sec) .. ('.%03d'):format(math.floor((usec or 0) / 1000))
  pending[#pending + 1] = ('%s %-5s [%d] %s: %s'):format(ts, NAMES[lvl], pid, scope, msg)
  if lvl == M.LEVELS.error or #pending > 200 then
    M.flush()
  end
end

--- Log a message. `fmt` is only formatted when the level is enabled.
---@param lvl 'error'|'warn'|'info'|'debug'|'trace'
---@param scope string  module name, e.g. 'runner'
---@param fmt string
function M.log(lvl, scope, fmt, ...)
  if not M.enabled then
    return
  end
  local n = M.LEVELS[lvl] or M.LEVELS.debug
  if n > level then
    return
  end
  local ok, msg = pcall(string.format, fmt, ...)
  push(n, scope, ok and msg or (fmt .. ' [format error: ' .. tostring(msg) .. ']'))
end

--- Shorthands: dbg.debug('runner', 'x=%d', 1)
for name in pairs(M.LEVELS) do
  M[name] = function(scope, fmt, ...)
    M.log(name, scope, fmt, ...)
  end
end

--- Is a level currently logged? (Guard for expensive messages.)
---@param lvl string
function M.on(lvl)
  return M.enabled and (M.LEVELS[lvl] or 4) <= level
end

--- Environment variables worth recording; values of secrets are replaced.
---@return table<string, string>
function M.p4_env()
  local out = {}
  for k, v in pairs(vim.uv.os_environ()) do
    if k:match('^P4') then
      out[k] = (k == 'P4PASSWD') and '<redacted>' or v
    end
  end
  return out
end

--- Write a session header (versions, config, environment).
local function header(reason)
  local cfg = vim.deepcopy(require('perforated.config').get())
  push(
    M.LEVELS.info,
    'debug',
    ('--- debug %s: level=%s file=%s'):format(reason, NAMES[level], path)
  )
  push(
    M.LEVELS.info,
    'debug',
    ('nvim=%s os=%s cwd=%s'):format(
      tostring(vim.version()),
      vim.uv.os_uname().sysname,
      vim.uv.cwd()
    )
  )
  push(M.LEVELS.info, 'debug', 'config=' .. vim.inspect(cfg, { newline = ' ', indent = '' }))
  push(M.LEVELS.info, 'debug', 'env=' .. vim.inspect(M.p4_env(), { newline = ' ', indent = '' }))
end

---@param opts { level: string?, file: string?, max_kb: integer? }?
---@param reason string?
function M.enable(opts, reason)
  opts = opts or {}
  local cfg = require('perforated.config').get().debug or {}
  level = M.LEVELS[opts.level or cfg.level or 'debug'] or M.LEVELS.debug
  path = vim.fs.normalize(opts.file or cfg.file or M.default_file())
  max_bytes = (opts.max_kb or cfg.max_kb or 5120) * 1024
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  M.enabled = true
  ensure_timer()
  header(reason or 'enabled')
  M.flush()
  if not M._leave then
    M._leave = vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('perforated.debug', { clear = true }),
      callback = function()
        M.flush()
      end,
    })
  end
end

function M.disable()
  if M.enabled then
    push(M.LEVELS.info, 'debug', '--- debug disabled')
    M.flush()
  end
  M.enabled = false
  stop_timer()
end

--- Write a diagnostic snapshot (workspaces, connection states, buffers, recent p4 calls).
function M.snapshot()
  if not M.enabled then
    M.enable(nil, 'enabled for snapshot')
  end
  push(M.LEVELS.info, 'snapshot', '--- snapshot begin')
  local wsmod = package.loaded['perforated.core.workspace']
  for _, ws in ipairs(wsmod and wsmod.list() or {}) do
    push(
      M.LEVELS.info,
      'snapshot',
      ('workspace %s mode=%s client=%s root=%s conn=%s(%s) idle=%s buffers=%d opened=%s stale=%s unresolved=%s sticky=%s'):format(
        ws.key,
        ws.mode,
        tostring(ws:client()),
        tostring(ws.root),
        ws.conn.state,
        tostring(ws.conn.last_error),
        tostring(ws.idle),
        vim.tbl_count(ws.buffers),
        tostring(ws.opened_count),
        tostring(ws.stale_count),
        tostring(ws.unresolved_count),
        tostring(ws.sticky_cl)
      )
    )
  end
  local bufmod = package.loaded['perforated.buffer']
  for buf, st in pairs(bufmod and bufmod.all() or {}) do
    push(
      M.LEVELS.info,
      'snapshot',
      ('buffer %d %s status=%s action=%s have=%s head=%s base=%s hunks=%d'):format(
        buf,
        st.path,
        st.status,
        tostring(st.rec and st.rec.action),
        tostring(st.rec and st.rec.haveRev),
        tostring(st.rec and st.rec.headRev),
        tostring(st.base_spec),
        #st.hunks
      )
    )
  end
  local q = package.loaded['perforated.core.queue']
  if q then
    local g = q.global()
    push(
      M.LEVELS.info,
      'snapshot',
      ('queue running=%d pending=%d paused=%s'):format(
        g.running,
        g:pending_count(),
        vim.inspect(g.paused, { newline = ' ', indent = '' })
      )
    )
  end
  for _, e in ipairs(require('perforated.core.log').entries()) do
    push(M.LEVELS.info, 'snapshot', 'recent p4: ' .. require('perforated.core.log').format(e))
  end
  push(M.LEVELS.info, 'snapshot', '--- snapshot end')
  M.flush()
end

--- Open the log file in a split (scrolled to the end).
function M.open()
  M.flush()
  local file = path or M.default_file()
  if not vim.uv.fs_stat(file) then
    return vim.notify('[perforated] no debug log yet: ' .. file)
  end
  vim.cmd('botright split ' .. vim.fn.fnameescape(file))
  vim.bo.autoread = true
  vim.cmd('normal! G')
end

--- Delete the log file (and its rotation).
function M.clear()
  local file = path or M.default_file()
  pending = {}
  os.remove(file)
  os.remove(file .. '.1')
end

--- Summarise stdin for logging: never the content of a login, only counts/heads of file lists.
---@param args string[]
---@param stdin string|string[]|nil
---@return string
function M.stdin_summary(args, stdin)
  if not stdin then
    return ''
  end
  for _, a in ipairs(args) do
    if a == 'login' or a == 'passwd' then
      return ' stdin=<redacted>'
    end
  end
  local lines = type(stdin) == 'table' and stdin or vim.split(stdin, '\n', { trimempty = true })
  local head = {}
  for i = 1, math.min(3, #lines) do
    head[i] = lines[i]
  end
  return (' stdin=%d line(s) [%s%s]'):format(
    #lines,
    table.concat(head, ', '),
    #lines > 3 and ', …' or ''
  )
end

-- Auto-enable from the environment or config on first load.
do
  local env = vim.env.PERFORATED_DEBUG
  local cfg = require('perforated.config').get().debug or {}
  if env and env ~= '' and env ~= '0' then
    M.enable({ level = M.LEVELS[env] and env or nil }, 'enabled by PERFORATED_DEBUG')
  elseif cfg.enabled then
    M.enable(nil, 'enabled by config')
  end
end

return M
