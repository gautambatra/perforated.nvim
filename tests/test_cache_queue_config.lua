local H = require('tests.helpers')
local T = MiniTest.new_set()

T['lru'] = MiniTest.new_set()

T['lru']['evicts least recently used by bytes'] = function()
  local lru = require('perforated.core.cache').lru(10)
  lru:set('a', 'aaaa') -- 4
  lru:set('b', 'bbbb') -- 8
  H.eq(lru:get('a'), 'aaaa') -- a is now most recent
  lru:set('c', 'cccc') -- 12 > 10 → evict b
  H.eq(lru:get('b'), nil)
  H.eq(lru:get('a'), 'aaaa')
  H.eq(lru:get('c'), 'cccc')
  H.eq(lru.size, 8)
  H.eq(lru.n, 2)
end

T['lru']['replacing a key re-accounts bytes'] = function()
  local lru = require('perforated.core.cache').lru(100)
  lru:set('a', 'xx')
  lru:set('a', 'xxxxx')
  H.eq(lru.size, 5)
  lru:delete('a')
  H.eq(lru.size, 0)
end

T['lru']['never caches an item larger than the budget'] = function()
  local lru = require('perforated.core.cache').lru(3)
  lru:set('big', 'abcd')
  H.eq(lru:has('big'), false)
  H.eq(lru.size, 0)
end

T['queue'] = MiniTest.new_set()

local function job(q, log, name, opts)
  opts = opts or {}
  local finish
  q:push({
    group = opts.group or 'g',
    priority = opts.priority,
    key = opts.key,
    force = opts.force,
    start = function(done)
      log[#log + 1] = 'start ' .. name
      finish = done
    end,
    cb = function(r)
      log[#log + 1] = 'done ' .. name .. ' ' .. tostring(r)
    end,
  })
  return function(r)
    finish(r)
  end
end

T['queue']['caps concurrency and runs in priority order'] = function()
  local q = require('perforated.core.queue').new(1)
  local log = {}
  local f1 = job(q, log, 'a', { priority = 3 })
  job(q, log, 'b', { priority = 3 })
  job(q, log, 'c', { priority = 1 })
  H.eq(log, { 'start a' })
  f1('x')
  -- c (interactive) overtakes b (background)
  H.eq(log, { 'start a', 'done a x', 'start c' })
end

T['queue']['dedupes identical keyed jobs'] = function()
  local q = require('perforated.core.queue').new(4)
  local log = {}
  local f1 = job(q, log, 'a', { key = 'k' })
  job(q, log, 'b', { key = 'k' })
  H.eq(log, { 'start a' })
  f1('r')
  H.eq(log, { 'start a', 'done a r', 'done b r' })
end

T['queue']['pause holds a group; force bypasses it'] = function()
  local q = require('perforated.core.queue').new(4)
  local log = {}
  q:pause('g')
  job(q, log, 'held')
  job(q, log, 'other', { group = 'h' })
  job(q, log, 'login', { force = true })
  H.eq(log, { 'start other', 'start login' })
  H.eq(q:pending_count('g'), 1)
  q:resume('g')
  H.eq(log, { 'start other', 'start login', 'start held' })
end

T['config'] = MiniTest.new_set()

T['config']['merges vim.g and setup(), reports unknown keys'] = function()
  local config = require('perforated.config')
  vim.g.perforated = { poll = { interval = 60 }, polll = 1, checkout = { dirs = { '/x' } } }
  config.set({ toast = { timeout = 0 } })
  local c = config.get()
  H.eq(c.poll.interval, 60)
  H.eq(c.poll.focus_throttle, 30)
  H.eq(c.toast.timeout, 0)
  H.eq(config.unknown_keys(), { 'polll' })
  vim.g.perforated = nil
  config._reset()
end

return T
