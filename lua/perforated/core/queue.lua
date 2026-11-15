--- Global job queue for p4 processes: concurrency cap, in-flight de-duplication, priorities
--- and per-group (per-workspace) pause/resume.

local M = {}

M.PRIORITY = { interactive = 1, buffer = 2, background = 3 }

---@class perforated.Job
---@field group string                     workspace key
---@field priority integer?                1 (highest) .. 3
---@field key string?                      de-duplication key
---@field force boolean?                   run even while the group is paused (e.g. `p4 login`)
---@field timeout integer?                 ms the work may take (nil/0: no limit), read by `start`
---@field start fun(done: fun(...))         begins the work; must call done exactly once
---@field cb fun(...)?                      completion callback
---@field cbs fun(...)[]?                   (keyed) callbacks of every caller sharing the job
---@field prio integer?                     (set by push) the FIFO it waits in
---@field running boolean?                  (set when started)

---@class perforated.Queue
---@field cap integer
---@field running integer
---@field pending perforated.Job[][]       one FIFO per priority
---@field waiters table<string, perforated.Job> key → the queued or running job callers share
---@field paused table<string, boolean>
local Queue = {}
Queue.__index = Queue

---@param cap integer
---@return perforated.Queue
function M.new(cap)
  return setmetatable({
    cap = cap,
    running = 0,
    pending = { {}, {}, {} },
    waiters = {},
    paused = {},
  }, Queue)
end

--- A timeout's limit in ms (nil or 0: none).
local function limit(timeout)
  return (timeout or 0) > 0 and timeout or math.huge
end

--- Queue a job. A job with the same key as one queued or running shares its result, so long
--- as that doesn't cut it short: one still waiting gets the longer timeout and the higher
--- priority of the two; one running with a shorter timeout isn't joined (it could give up
--- before this one would), so this one runs too, and later callers share it instead.
---@param job perforated.Job
function Queue:push(job)
  local prio = math.max(1, math.min(3, job.priority or M.PRIORITY.interactive))
  if job.key then
    local shared = self.waiters[job.key]
    if shared and (not shared.running or limit(shared.timeout) >= limit(job.timeout)) then
      shared.cbs[#shared.cbs + 1] = job.cb
      if not shared.running then
        if limit(job.timeout) > limit(shared.timeout) then
          shared.timeout = job.timeout
        end
        if prio < shared.prio then
          local fifo = self.pending[shared.prio]
          for i, queued in ipairs(fifo) do
            if queued == shared then
              table.remove(fifo, i)
              break
            end
          end
          shared.prio = prio
          table.insert(self.pending[prio], shared)
        end
      end
      return
    end
    job.cbs = { job.cb }
    self.waiters[job.key] = job
  end
  job.prio = prio
  table.insert(self.pending[prio], job)
  self:_pump()
end

function Queue:_next()
  for _, fifo in ipairs(self.pending) do
    for i, job in ipairs(fifo) do
      if job.force or not self.paused[job.group] then
        return table.remove(fifo, i)
      end
    end
  end
end

function Queue:_pump()
  while self.running < self.cap do
    local job = self:_next()
    if not job then
      return
    end
    self.running = self.running + 1
    job.running = true
    local finished = false
    job.start(function(...)
      if finished then
        return
      end
      finished = true
      self.running = self.running - 1
      local cbs = job.cbs or { job.cb }
      if job.key and self.waiters[job.key] == job then
        self.waiters[job.key] = nil
      end
      for _, cb in ipairs(cbs) do
        if cb then
          cb(...)
        end
      end
      self:_pump()
    end)
  end
end

---@param group string
function Queue:pause(group)
  local dbg = package.loaded['perforated.core.debug']
  if dbg then
    dbg.log('debug', 'queue', 'pause %s (pending %d)', group, self:pending_count(group))
  end
  self.paused[group] = true
end

---@param group string
function Queue:resume(group)
  local dbg = package.loaded['perforated.core.debug']
  if dbg then
    dbg.log('debug', 'queue', 'resume %s (pending %d)', group, self:pending_count(group))
  end
  self.paused[group] = nil
  self:_pump()
end

--- Number of jobs waiting (not running).
---@param group string?
---@return integer
function Queue:pending_count(group)
  local n = 0
  for _, fifo in ipairs(self.pending) do
    for _, job in ipairs(fifo) do
      if not group or job.group == group then
        n = n + 1
      end
    end
  end
  return n
end

local global ---@type perforated.Queue?

--- The shared queue (cap from config.runner.concurrency).
---@return perforated.Queue
function M.global()
  if not global then
    global = M.new(require('perforated.config').get().runner.concurrency)
  end
  return global
end

--- Test helper: drop the shared queue.
function M._reset()
  global = nil
end

return M
