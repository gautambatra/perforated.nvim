--- Spawn p4 asynchronously. Never uses a shell, never blocks the UI thread.
---
--- Output is requested as `-Mj -ztag` (JSON lines) and decoded incrementally in the stdout
--- callback; the final callback runs on the main loop.

local parse = require('perforated.core.parse')
local env = require('perforated.core.env')
local log = require('perforated.core.log')
local dbg = require('perforated.core.debug')

local M = {}

---@class perforated.RunSpec
---@field args string[]          p4 command and arguments (after global options)
---@field cwd string             working directory (the workspace anchor)
---@field globals string[]?      extra global options, e.g. { '-c', 'client' }
---@field tagged boolean?        default true: add `-Mj -ztag` and parse records
---@field stdin string|string[]? data for stdin (a list is joined with newlines); nil = closed
---@field timeout integer?       ms; 0/nil = no timeout
---@field env_mode ('internal'|'user')? default 'internal'
---@field ws string?             workspace key, for the log
---@field bin string?            p4 executable override

---@class perforated.RunResult
---@field ok boolean             exit 0, no severity>=3 message, not timed out
---@field code integer
---@field signal integer
---@field records table[]
---@field warnings string[]
---@field errors string[]
---@field stdout string?         raw stdout (untagged calls only)
---@field stderr string
---@field ms number
---@field timed_out boolean
---@field argv string[]
---@field all table[]?          tagged: every record incl. messages, in output order

M.TIMEOUT_CODE = 124 -- vim.system's exit code on timeout
M.KILL_GRACE = 2000 -- ms between SIGTERM (timeout) and SIGKILL

---@param spec perforated.RunSpec
---@param cb fun(res: perforated.RunResult)
---@return vim.SystemObj?
function M.run(spec, cb)
  local tagged = spec.tagged ~= false
  local argv = { spec.bin or env.p4_bin() or 'p4' }
  if tagged then
    argv[#argv + 1] = '-Mj'
    argv[#argv + 1] = '-ztag'
  end
  for _, g in ipairs(spec.globals or {}) do
    argv[#argv + 1] = g
  end
  for _, a in ipairs(spec.args) do
    argv[#argv + 1] = a
  end

  local stdin = spec.stdin
  if type(stdin) == 'table' then
    stdin = table.concat(stdin, '\n') .. '\n'
  end

  local recs, bad = {}, 0
  local out_chunks = {}
  local feed
  if tagged then
    feed = parse.line_splitter(function(line)
      local rec = parse.json_line(line)
      if rec then
        recs[#recs + 1] = rec
      elseif not line:find('^%s*$') then
        bad = bad + 1
      end
    end)
  end

  local t0 = vim.uv.hrtime()
  local started = os.time()
  local kill_timer ---@type uv.uv_timer_t?
  local killed = false

  local function finish(obj)
    if kill_timer then
      kill_timer:stop()
      kill_timer:close()
      kill_timer = nil
    end
    local res = {
      code = obj.code,
      signal = obj.signal,
      stderr = obj.stderr or '',
      ms = (vim.uv.hrtime() - t0) / 1e6,
      timed_out = killed or (obj.code == M.TIMEOUT_CODE and (spec.timeout or 0) > 0),
      argv = argv,
    }
    if tagged then
      local p = parse.classify(recs, bad)
      res.records, res.warnings, res.errors = p.records, p.warnings, p.errors
      res.all = recs -- records and messages in output order
    else
      res.records, res.warnings, res.errors = {}, {}, {}
      res.stdout = table.concat(out_chunks)
    end
    res.ok = res.code == 0 and #res.errors == 0 and not res.timed_out
    local err = res.errors[1]
    if not err and res.code ~= 0 then
      err = res.timed_out and ('timed out after %dms'):format(spec.timeout)
        or vim.trim(res.stderr):match('[^\n]*$')
        or ('exit ' .. res.code)
      if err == '' then
        err = 'exit ' .. res.code
      end
    end
    if dbg.enabled then
      dbg.log(
        err and 'warn' or 'debug',
        'runner',
        'done %s code=%s %.0fms records=%d warnings=%d errors=%d%s%s%s',
        table.concat(argv, ' ', 2),
        tostring(res.code),
        res.ms,
        #res.records,
        #res.warnings,
        #res.errors,
        res.timed_out and ' TIMED-OUT' or '',
        err and (' err=' .. err) or '',
        (vim.trim(res.stderr) ~= '' and #res.errors == 0)
            and (' stderr=' .. vim.trim(res.stderr):gsub('\n', ' | '))
          or ''
      )
      if dbg.on('trace') then
        for _, w in ipairs(res.warnings) do
          dbg.log('trace', 'runner', '  warning: %s', w)
        end
      end
    end
    log.add({
      time = started,
      ms = res.ms,
      argv = argv,
      cwd = spec.cwd,
      code = res.code,
      records = tagged and #res.records or nil,
      err = err,
      ws = spec.ws,
    })
    cb(res)
  end

  if dbg.enabled then
    dbg.log(
      'debug',
      'runner',
      'start %s cwd=%s env=%s timeout=%s%s',
      table.concat(argv, ' ', 2),
      spec.cwd,
      spec.env_mode or 'internal',
      tostring(spec.timeout),
      dbg.stdin_summary(argv, spec.stdin)
    )
  end
  local ok, obj = pcall(vim.system, argv, {
    cwd = spec.cwd,
    env = env.child_env(spec.cwd, spec.env_mode or 'internal'),
    clear_env = true,
    stdin = stdin or false,
    timeout = (spec.timeout and spec.timeout > 0) and spec.timeout or nil,
    text = true,
    stdout = function(_, chunk)
      if tagged then
        feed(chunk)
      elseif chunk then
        out_chunks[#out_chunks + 1] = chunk
      end
    end,
  }, function(o)
    vim.schedule(function()
      finish(o)
    end)
  end)

  if ok and spec.timeout and spec.timeout > 0 then
    -- vim.system only sends SIGTERM on timeout; escalate if the process ignores it.
    kill_timer = vim.uv.new_timer()
    kill_timer:start(spec.timeout + M.KILL_GRACE, 0, function()
      killed = true
      pcall(obj.kill, obj, 'sigkill')
    end)
  end

  if not ok then
    -- Spawn failure (missing binary, bad cwd): report asynchronously like any other failure.
    vim.schedule(function()
      finish({ code = -1, signal = 0, stderr = tostring(obj) })
    end)
    return nil
  end
  return obj
end

return M
