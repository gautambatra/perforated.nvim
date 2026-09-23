local H = require('tests.helpers')
local async = require('perforated.core.async')
local T = MiniTest.new_set()

local function later(ms, value)
  return function(cb)
    vim.defer_fn(function()
      cb(value)
    end, ms)
  end
end

T['run/await sequences callback APIs'] = function()
  local out
  async.run(function()
    local a = async.await(later(10, 1))
    local b = async.await(later(5, 2))
    out = a + b
  end)
  vim.wait(1000, function()
    return out ~= nil
  end)
  H.eq(out, 3)
end

T['all runs in parallel and keeps order'] = function()
  local out
  local t0 = vim.uv.now()
  async.run(function()
    out = async.all({ later(60, 'a'), later(10, 'b'), later(30, 'c') })
  end)
  vim.wait(1000, function()
    return out ~= nil
  end)
  H.eq(out, { 'a', 'b', 'c' })
  H.eq(vim.uv.now() - t0 < 150, true)
end

T['errors reach on_done'] = function()
  local ok, err
  async.run(function()
    async.await(later(1))
    error('boom')
  end, function(o, e)
    ok, err = o, e
  end)
  vim.wait(1000, function()
    return ok ~= nil
  end)
  H.eq(ok, false)
  H.eq(err:find('boom', 1, true) ~= nil, true)
end

T['debounce collapses bursts'] = function()
  local calls = {}
  local d, cancel = async.debounce(30, function(x)
    calls[#calls + 1] = x
  end)
  d(1)
  d(2)
  d(3)
  vim.wait(200, function()
    return #calls > 0
  end)
  vim.wait(50)
  H.eq(calls, { 3 })
  cancel()
end

T['throttle_by_key allows one call per key per window'] = function()
  local n = 0
  local t = async.throttle_by_key(1000, function()
    n = n + 1
  end)
  H.eq(t('a'), true)
  H.eq(t('a'), false)
  H.eq(t('b'), true)
  H.eq(n, 2)
end

return T
