--- Long-running p4 operations (sync, submit): watch and stop them.
---
---   * a progress message that updates while the job runs (file count, last file, elapsed; for a
---     sync, files and bytes out of p4's totals, and a percentage);
---   * `:P4 jobs`: a float listing running jobs, refreshed live; `x` stops the one under the
---     cursor, `q` closes;
---   * `:P4 cancel`: stops every running job (SIGTERM, then SIGKILL after 2 s);
---   * Ctrl+c on a job's busy pop-up: stops that job.
---
--- Stopping a sync midway is safe: p4 updates the have list file by file.

local M = {}

local progress = require('perforated.ui.progress')

---@class perforated.Job
---@field id integer
---@field ws perforated.Workspace
---@field title string
---@field started number        hrtime
---@field count integer          files streamed so far (records naming one; once per file)
---@field total integer?         how many files the caller expects (`2/4 files`)
---@field last_key string?       the file the last counted record named
---@field total_files integer?   `totalFileCount` of the first sync record
---@field total_bytes integer?   `totalFileSize` of the first sync record
---@field files integer          file records seen (each counts towards `total_files`)
---@field bytes integer          their `fileSize`, added up
---@field last string?           last file seen
---@field ctl { cancel: fun() }? set once the process runs
---@field cancel_requested boolean?
---@field prog perforated.Progress
---@field done boolean?

local jobs = {} ---@type perforated.Job[]
local next_id = 0
local timer = nil ---@type uv.uv_timer_t?
local float = nil ---@type { buf: integer, win: integer }?

local function elapsed(job)
  local s = math.floor((vim.uv.hrtime() - job.started) / 1e9)
  return s >= 60 and ('%dm%02ds'):format(math.floor(s / 60), s % 60) or (s .. 's')
end

--- `1234567` → `1,234,567`.
local function grouped(n)
  local s = tostring(n)
  local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return (out:gsub('^,', ''))
end

--- `done/total` in the unit that suits the total: `45.2/160.0 MB`.
local function bytes_of(done, total)
  local unit, div = 'bytes', 1
  if total >= 1048576 then
    unit, div = 'MB', 1048576
  elseif total >= 1024 then
    unit, div = 'KB', 1024
  end
  local fmt = div == 1 and '%d/%d %s' or '%.1f/%.1f %s'
  return fmt:format(done / div, total / div, unit)
end

--- How far a job with p4's totals (a sync) has got, 0–100; nil without them.
---@param job perforated.Job
---@return integer?
function M.percent(job)
  if not job.total_files or job.total_files == 0 then
    return nil
  end
  return math.min(100, math.floor(job.files * 100 / job.total_files))
end

local function describe(job)
  local s
  local pct = M.percent(job)
  if pct then
    s = ('%s · %s · %s/%s files (%d%%)'):format(
      job.title,
      elapsed(job),
      grouped(job.files),
      grouped(job.total_files),
      pct
    )
    if job.total_bytes and job.total_bytes > 0 then
      s = s .. ' · ' .. bytes_of(math.min(job.bytes, job.total_bytes), job.total_bytes)
    end
  elseif job.total then
    s = ('%s · %s · %d/%d files'):format(
      job.title,
      elapsed(job),
      math.min(job.count, job.total),
      job.total
    )
  else
    s = ('%s · %s · %d file(s)'):format(job.title, elapsed(job), job.count)
  end
  if job.cancel_requested then
    s = s .. ' · stopping…'
  elseif job.last then
    s = s .. ' · ' .. job.last
  end
  return s
end

local function render_float()
  if not float or not vim.api.nvim_win_is_valid(float.win) then
    float = nil
    return
  end
  local lines = {}
  for _, j in ipairs(jobs) do
    lines[#lines + 1] = describe(j)
  end
  if #lines == 0 then
    lines = { 'no running jobs' }
  end
  vim.bo[float.buf].modifiable = true
  vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
  vim.bo[float.buf].modifiable = false
end

local function tick()
  for _, j in ipairs(jobs) do
    if j.prog then -- quiet jobs (resolve) have no progress item: their caller shows its own
      progress.update(j.prog, describe(j), M.percent(j))
    end
  end
  render_float()
  if #jobs == 0 and not float and timer then
    timer:stop()
  end
end

local function ensure_timer()
  timer = timer or vim.uv.new_timer()
  if not timer:is_active() then
    timer:start(500, 500, vim.schedule_wrap(tick))
  end
end

--- Register a job. Pass the returned table's fields as `ws:run` options:
---   ws:run(args, vim.tbl_extend('force', opts, job.run_opts), cb)
---@param ws perforated.Workspace
---@param title string
---@param opts { quiet: boolean?, total: integer? }?  quiet: no start / result pop-ups (the
---  caller shows its own); total: how many files it will touch, when known
---@return perforated.Job job, table run_opts
function M.start(ws, title, opts)
  next_id = next_id + 1
  local job = {
    id = next_id,
    ws = ws,
    title = title,
    started = vim.uv.hrtime(),
    count = 0,
    total = opts and opts.total,
    files = 0,
    bytes = 0,
    prog = not (opts and opts.quiet)
      and progress.start('p4', title .. '…  (:P4 jobs to watch, :P4 cancel to stop)'),
  }
  jobs[#jobs + 1] = job
  ensure_timer()
  local run_opts = {
    timeout = 0,
    on_spawn = function(ctl)
      job.ctl = ctl
      if job.cancel_requested then
        ctl.cancel()
      end
    end,
    on_record = function(rec) -- fast context: plain Lua only
      -- A file counts once: p4 can stream several records for one (resolve: the resolve
      -- record, a "Diff chunks" message, a "merge from" record), and messages name none.
      local key = rec.clientFile or rec.depotFile
      if key and key ~= job.last_key then
        job.count = job.count + 1
        job.last_key = key
      end
      job.last = rec.depotFile or rec.clientFile or job.last
      -- p4 sync's first record carries the totals; each file's record its size. Messages
      -- (no action) aren't files.
      if rec.totalFileCount and not job.total_files then
        job.total_files = tonumber(rec.totalFileCount)
        job.total_bytes = tonumber(rec.totalFileSize)
      end
      if rec.action then
        job.files = job.files + 1
        job.bytes = job.bytes + (tonumber(rec.fileSize) or 0)
      end
    end,
  }
  return job, run_opts
end

--- Run a command that changes files as a quiet job: it has no call timeout, because killing it
--- would leave the work half done, and the user can stop it instead. Every way of stopping it
--- ends the same way: a warning here and `res.stopped` for the caller, which reports nothing
--- more but still refreshes (part of the work may be done).
---@param ws perforated.Workspace
---@param title string  for `:P4 jobs`
---@param args string[]
---@param opts table?  `ws:run` options, plus:
---  * busy string?: the pop-up; delay integer?: wait this many ms before showing it, so that a
---    quick command doesn't flash one
---  * task table?: the caller's `toast.task` instead (which the caller closes)
---  * effect string?: past participle for the warning, e.g. 'reverted'; single boolean?: one file
---  * verb string?: names the command in the warning (default: `args[1]`)
---  * total integer?: how many files it will touch, for `:P4 jobs` (`2/4 files`)
---@param cb fun(res: perforated.RunResult)
function M.run(ws, title, args, opts, cb)
  opts = opts or {}
  local toast = require('perforated.ui.toast')
  local job, run_opts = M.start(ws, title, { quiet = true, total = opts.total })
  local function cancel()
    M.cancel(job)
  end
  local close = function() end
  local finished = false
  local function show()
    if not finished then
      close = toast.busy(opts.busy, { cancel = cancel })
    end
  end
  if opts.task then
    opts.task.resume(cancel)
  elseif opts.busy and opts.delay then
    vim.defer_fn(show, opts.delay)
  elseif opts.busy then
    show()
  end
  local run = { stdin = opts.stdin, globals = opts.globals, priority = opts.priority }
  ws:run(args, vim.tbl_extend('force', run, run_opts), function(res)
    finished = true
    close()
    res.stopped = res.cancelled or res.timed_out
    M.finish(job, title)
    if res.stopped then
      local msg = ('%s %s'):format(
        opts.verb or args[1],
        res.cancelled and 'cancelled' or 'timed out'
      )
      if opts.effect then
        msg = ('%s: %s may already be %s'):format(
          msg,
          opts.single and 'the file' or 'some files',
          opts.effect
        )
      end
      toast.notify('[perforated] ' .. msg, vim.log.levels.WARN)
    end
    cb(res)
  end)
end

--- Mark a job finished (and report through its progress item).
---@param job perforated.Job
---@param msg string
---@param failed boolean|'warn'|nil  'warn': finished, but something needs attention
function M.finish(job, msg, failed)
  job.done = true
  require('perforated.core.debug').timing(
    'job: ' .. (job.title:match('^%S+') or job.title),
    (vim.uv.hrtime() - job.started) / 1e6
  )
  for i, j in ipairs(jobs) do
    if j == job then
      table.remove(jobs, i)
      break
    end
  end
  if job.prog then
    progress.finish(job.prog, msg .. (' (%s)'):format(elapsed(job)), failed)
  end
  render_float()
end

--- Stop a job (or all of them).
---@param job perforated.Job?
function M.cancel(job)
  local list = job and { job } or vim.list_extend({}, jobs)
  if #list == 0 then
    return require('perforated.ui.toast').notify('[perforated] no running jobs')
  end
  for _, j in ipairs(list) do
    j.cancel_requested = true
    if j.ctl then
      j.ctl.cancel()
    end
  end
  require('perforated.ui.toast').notify(('[perforated] stopping %d job(s)…'):format(#list))
  render_float()
end

---@return perforated.Job[]
function M.list()
  return jobs
end

--- `:P4 jobs`: live list of running jobs.
function M.show()
  if float and vim.api.nvim_win_is_valid(float.win) then
    return vim.api.nvim_set_current_win(float.win)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(100, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 2,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = math.max(3, math.min(10, #jobs)),
    style = 'minimal',
    border = 'rounded',
    title = ' p4 jobs ',
    footer = ' x stop · q close ',
    footer_pos = 'right',
  })
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  require('perforated.ui.stack').register(win)
  vim.wo[win][0].cursorline = true
  float = { buf = buf, win = win }
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    float = nil
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })
  vim.keymap.set('n', 'x', function()
    local j = jobs[vim.api.nvim_win_get_cursor(0)[1]]
    if j then
      M.cancel(j)
    end
  end, { buffer = buf, nowait = true })
  render_float()
  ensure_timer()
end

function M._reset()
  jobs = {}
  if timer then
    timer:stop()
  end
end

return M
