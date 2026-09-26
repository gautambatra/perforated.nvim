--- Long-running p4 operations (sync, submit): watch and stop them.
---
---   * a progress message that updates while the job runs (file count, last file, elapsed);
---   * `:P4 jobs`: a float listing running jobs, refreshed live; `x` stops the one under the
---     cursor, `q` closes;
---   * `:P4 cancel`: stops every running job (SIGTERM, then SIGKILL after 2 s).
---
--- Stopping a sync midway is safe: p4 updates the have list file by file.

local M = {}

local progress = require('perforated.ui.progress')

---@class perforated.Job
---@field id integer
---@field ws perforated.Workspace
---@field title string
---@field started number        hrtime
---@field count integer          records streamed so far
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

local function describe(job)
  local s = ('%s · %s · %d file(s)'):format(job.title, elapsed(job), job.count)
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
    progress.update(j.prog, describe(j))
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
---@return perforated.Job job, table run_opts
function M.start(ws, title)
  next_id = next_id + 1
  local job = {
    id = next_id,
    ws = ws,
    title = title,
    started = vim.uv.hrtime(),
    count = 0,
    prog = progress.start('p4', title .. '…  (:P4 jobs to watch, :P4 cancel to stop)'),
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
      job.count = job.count + 1
      job.last = rec.depotFile or rec.clientFile or job.last
    end,
  }
  return job, run_opts
end

--- Mark a job finished (and report through its progress item).
---@param job perforated.Job
---@param msg string
---@param failed boolean?
function M.finish(job, msg, failed)
  job.done = true
  for i, j in ipairs(jobs) do
    if j == job then
      table.remove(jobs, i)
      break
    end
  end
  progress.finish(job.prog, msg .. (' (%s)'):format(elapsed(job)), failed)
  render_float()
end

--- Stop a job (or all of them).
---@param job perforated.Job?
function M.cancel(job)
  local list = job and { job } or vim.list_extend({}, jobs)
  if #list == 0 then
    return vim.notify('[perforated] no running jobs')
  end
  for _, j in ipairs(list) do
    j.cancel_requested = true
    if j.ctl then
      j.ctl.cancel()
    end
  end
  vim.notify(('[perforated] stopping %d job(s)…'):format(#list))
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
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  vim.wo[win].cursorline = true
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
