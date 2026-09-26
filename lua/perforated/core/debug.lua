--- Debug logging front end. Kept tiny because every module on the activation path requires it:
--- while debugging is off, calls are a boolean check and nothing else loads. The implementation
--- (buffering, rotation, snapshot, …) lives in core/debug_impl.lua and loads when enabled.
---
--- Enable with any of: `debug = { enabled = true }`, env `PERFORATED_DEBUG=1|<level>`, or
--- `:P4 debug on [level]`.

local M = { enabled = false }

local impl ---@type table?

local function I()
  impl = impl or require('perforated.core.debug_impl')
  return impl
end

M.LEVELS = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }

---@param lvl 'error'|'warn'|'info'|'debug'|'trace'
---@param scope string
---@param fmt string
function M.log(lvl, scope, fmt, ...)
  if M.enabled then
    I().log(lvl, scope, fmt, ...)
  end
end

for name in pairs(M.LEVELS) do
  M[name] = function(scope, fmt, ...)
    if M.enabled then
      I().log(name, scope, fmt, ...)
    end
  end
end

--- UI timings for `:P4 debug timings`: per name, count / total / max / last (fixed memory).
M._timings = {}

--- Record how long something took (always on: one table update).
---@param name string  e.g. 'client view: refresh'
---@param ms number
function M.timing(name, ms)
  local t = M._timings[name]
  if not t then
    t = { n = 0, total = 0, max = 0, last = 0 }
    M._timings[name] = t
  end
  t.n, t.total, t.last = t.n + 1, t.total + ms, ms
  if ms > t.max then
    t.max = ms
  end
  if M.enabled then
    I().log('debug', 'timing', '%s: %.1fms', name, ms)
  end
end

--- Is a level currently logged? (Guard for expensive messages.)
---@param lvl string
function M.on(lvl)
  return M.enabled and I().on(lvl)
end

function M.enable(opts, reason)
  I().enable(opts, reason)
  M.enabled = true
end

--- Snapshot turns logging on if needed (through this front end, so the flag stays in sync).
function M.snapshot()
  if not M.enabled then
    M.enable(nil, 'enabled for snapshot')
  end
  I().snapshot()
end

function M.disable()
  if impl then
    impl.disable()
  end
  M.enabled = false
end

-- Everything else (flush, snapshot, open, clear, file, default_file, stdin_summary, p4_env)
-- forwards to the implementation.
setmetatable(M, {
  __index = function(_, k)
    return I()[k]
  end,
})

-- Auto-enable from the environment or config on first load.
do
  local env = vim.env.PERFORATED_DEBUG
  if env and env ~= '' and env ~= '0' then
    M.enable({ level = M.LEVELS[env] and env or nil }, 'enabled by PERFORATED_DEBUG')
  elseif (require('perforated.config').get().debug or {}).enabled then
    M.enable(nil, 'enabled by config')
  end
end

return M
