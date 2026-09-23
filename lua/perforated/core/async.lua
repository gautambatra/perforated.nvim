--- Minimal coroutine helpers. Callback-style APIs stay the primitive; these helpers let
--- multi-step flows read sequentially without blocking the UI.
---
---   async.run(function()
---     local res = async.await(ws.run, ws, { 'info' }, {})
---     ...
---   end)

local M = {}

--- Run `fn` in a new coroutine. Errors are reported (not swallowed) via vim.notify.
---@param fn fun(...)
---@param on_done fun(ok: boolean, ...)?
function M.run(fn, on_done, ...)
  local co = coroutine.create(fn)
  local function step(...)
    local ret = { coroutine.resume(co, ...) }
    local ok = ret[1]
    if not ok then
      local err = debug.traceback(co, ret[2])
      if on_done then
        on_done(false, err)
      else
        vim.schedule(function()
          vim.notify('[perforated] ' .. err, vim.log.levels.ERROR)
        end)
      end
      return
    end
    if coroutine.status(co) == 'dead' then
      if on_done then
        on_done(true, unpack(ret, 2, table.maxn(ret)))
      end
      return
    end
    -- Yielded: ret[2] is a function taking the resume callback.
    local yielded = ret[2]
    yielded(step)
  end
  step(...)
  return co
end

--- Call a callback-style function (callback as last argument) and wait for its result.
--- Must be called inside `M.run`.
---@param fn function
---@return any ...
function M.await(fn, ...)
  local args = { ... }
  local n = select('#', ...)
  return coroutine.yield(function(resume)
    args[n + 1] = resume
    fn(unpack(args, 1, n + 1))
  end)
end

--- Wait for the next main-loop tick (safe place to call nvim API after a fast event).
function M.main()
  if not vim.in_fast_event() then
    return
  end
  coroutine.yield(function(resume)
    vim.schedule(resume)
  end)
end

--- Run several callback-style thunks in parallel; returns their first results in order.
---@param thunks (fun(cb: fun(...)))[]
---@return any[]
function M.all(thunks)
  return coroutine.yield(function(resume)
    local results, left = {}, #thunks
    if left == 0 then
      return resume(results)
    end
    for i, thunk in ipairs(thunks) do
      thunk(function(r)
        results[i] = r
        left = left - 1
        if left == 0 then
          resume(results)
        end
      end)
    end
  end)
end

--- Trailing debounce. Returns a function that delays `fn` until `ms` elapsed since last call.
---@param ms integer
---@param fn function
---@return function debounced, function cancel
function M.debounce(ms, fn)
  local timer = assert(vim.uv.new_timer())
  local args
  local function debounced(...)
    args = { n = select('#', ...), ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args, 1, args.n))
      end)
    end)
  end
  local function cancel()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  return debounced, cancel
end

--- Allow at most one run per `ms` per key; the first call runs immediately.
---@param ms integer
---@param fn fun(key: any, ...)
---@return fun(key: any, ...): boolean ran
function M.throttle_by_key(ms, fn)
  local last = {}
  return function(key, ...)
    local now = vim.uv.now()
    if last[key] and now - last[key] < ms then
      return false
    end
    last[key] = now
    fn(key, ...)
    return true
  end
end

return M
