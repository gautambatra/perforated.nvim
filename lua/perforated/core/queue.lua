--- Global job queue for p4 processes: concurrency cap, in-flight de-duplication, priorities
--- and per-group (per-workspace) pause/resume.

local M = {}

M.PRIORITY = { interactive = 1, buffer = 2, background = 3 }

---@class perforated.Job
---@field group string                     workspace key
---@field priority integer?                1 (highest) .. 3
---@field key string?                      de-duplication key
---@field force boolean?                   run even while the group is paused (e.g. `p4 login`)
---@field start fun(done: fun(...))         begins the work; must call done exactly once
---@field cb fun(...)?                      completion callback

---@class perforated.Queue
---@field cap integer
---@field running integer
---@field pending perforated.Job[][]       one FIFO per priority
---@field waiters table<string, fun(...)[]> key → callbacks of jobs merged into one
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

---@param job perforated.Job
function Queue:push(job)
  if job.key then
    local w = self.waiters[job.key]
    if w then
      -- Identical job already queued or running: share its result.
      w[#w + 1] = job.cb
      return
    end
    self.waiters[job.key] = { job.cb }
  end
  local prio = math.max(1, math.min(3, job.priority or M.PRIORITY.interactive))
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
    local finished = false
    job.start(function(...)
      if finished then
        return
      end
      finished = true
      self.running = self.running - 1
      local cbs
      if job.key then
        cbs = self.waiters[job.key] or {}
        self.waiters[job.key] = nil
      else
        cbs = { job.cb }
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
