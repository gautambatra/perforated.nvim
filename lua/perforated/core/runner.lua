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
---@field on_record fun(rec: table)?  each decoded record as it streams in (fast context: no API calls)
---@field keep_records boolean? default true; false: data records only go to on_record (messages are kept), so a huge output (sync of 100k files) isn't held in memory
---@field on_spawn fun(ctl: { cancel: fun() })?  called once the process runs; cancel() stops it

---@class perforated.RunResult
---@field ok boolean             exit 0, no severity>=3 message, not timed out
---@field code integer
---@field signal integer
---@field records table[]       empty with keep_records = false
---@field count integer          data records seen (kept or not)
---@field warnings string[]
---@field errors string[]
---@field stdout string?         raw stdout (untagged calls only)
---@field stderr string
---@field ms number
---@field timed_out boolean
---@field argv string[]
---@field all table[]?          tagged: every record incl. messages, in output order
---@field cancelled boolean?     stopped by the user (on_spawn's cancel)
---@field err string?           why it failed, in one line (a p4 error, "timed out after …", …)

--- Did the run stop before p4 finished its answer? Timed out, cancelled, killed, or exited
--- with a failure p4 gave no message for (a crash, a dropped connection). Its records may be
--- only the first part of the answer: what's missing from them is unknown, not absent.
---@param res perforated.RunResult
---@return boolean
function M.cut(res)
  return res.timed_out == true or res.cancelled == true or (not res.ok and #(res.errors or {}) == 0)
end

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

  local recs, bad, count = {}, 0, 0
  local keep = spec.keep_records ~= false
  local out_chunks = {}
  local feed
  if tagged then
    feed = parse.line_splitter(function(line)
      local rec = parse.json_line(line)
      if rec then
        local message = parse.is_message(rec)
        if not message then
          count = count + 1
        end
        if keep or message then
          recs[#recs + 1] = rec
        end
        if spec.on_record then
          spec.on_record(rec)
        end
      elseif not line:find('^%s*$') then
        bad = bad + 1
      end
    end)
  end

  local t0 = vim.uv.hrtime()
  local started = os.time()
  local kill_timer ---@type uv.uv_timer_t?
  local killed = false
  local cancelled = false

  local function finish(obj)
    if kill_timer then
      kill_timer:stop()
      kill_timer:close()
      kill_timer = nil
    end
    -- A process killed by a signal exits with code 0 (libuv reports the signal separately):
    -- never mistake a crashed or externally killed p4 (truncated output) for a success.
    local code = obj.code
    if code == 0 and (obj.signal or 0) ~= 0 then
      code = 128 + obj.signal
    end
    local res = {
      code = code,
      signal = obj.signal,
      stderr = obj.stderr or '',
      ms = (vim.uv.hrtime() - t0) / 1e6,
      timed_out = not cancelled
        and (killed or (obj.code == M.TIMEOUT_CODE and (spec.timeout or 0) > 0)),
      cancelled = cancelled,
      argv = argv,
    }
    if tagged then
      local p = parse.classify(recs, bad)
      res.records, res.warnings, res.errors = p.records, p.warnings, p.errors
      res.all = recs -- records and messages in output order
      res.count = count
    else
      res.records, res.warnings, res.errors = {}, {}, {}
      res.count = 0
      res.stdout = table.concat(out_chunks)
    end
    res.ok = res.code == 0 and #res.errors == 0 and not res.timed_out and not cancelled
    local err = res.errors[1]
    if cancelled then
      err = 'cancelled'
    elseif not err and res.code ~= 0 then
      err = res.timed_out and ('timed out after %dms'):format(spec.timeout)
        or vim.trim(res.stderr):match('[^\n]*$')
        or ('exit ' .. res.code)
      if err == '' then
        err = 'exit ' .. res.code
      end
    end
    res.err = err
    if dbg.enabled then
      dbg.log(
        err and 'warn' or 'debug',
        'runner',
        'done %s code=%s %.0fms records=%d warnings=%d errors=%d%s%s%s',
        table.concat(argv, ' ', 2),
        tostring(res.code),
        res.ms,
        res.count,
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
      records = tagged and res.count or nil,
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

  if ok and spec.on_spawn then
    spec.on_spawn({
      cancel = function()
        if cancelled then
          return
        end
        cancelled = true
        pcall(obj.kill, obj, 'sigterm')
        local t = vim.uv.new_timer()
        t:start(M.KILL_GRACE, 0, function()
          t:close()
          pcall(obj.kill, obj, 'sigkill')
        end)
      end,
    })
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
