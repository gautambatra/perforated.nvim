local H = require('tests.helpers')
local engine = require('perforated.diff.engine')
local T = MiniTest.new_set()

T['hunk types and ranges'] = function()
  local base = { 'a', 'b', 'c', 'd' }
  local cur = { 'a', 'B', 'c', 'x', 'd' }
  local h = engine.hunks(base, cur)
  H.eq(#h, 2)
  H.eq(h[1].type, 'change')
  H.eq({ engine.range(h[1]) }, { 2, 2 })
  H.eq(h[2].type, 'add')
  H.eq({ engine.range(h[2]) }, { 4, 4 })
end

T['deletions sit on the line above (min 1)'] = function()
  local h = engine.hunks({ 'a', 'b', 'c' }, { 'a', 'c' })
  H.eq(h[1].type, 'delete')
  H.eq({ engine.range(h[1]) }, { 1, 1 })
  h = engine.hunks({ 'a', 'b' }, { 'b' })
  H.eq({ engine.range(h[1]) }, { 1, 1 })
end

T['empty base = everything added'] = function()
  local h = engine.hunks({}, { 'x', 'y' })
  H.eq(h, { { type = 'add', a_start = 0, a_count = 0, b_start = 1, b_count = 2 } })
end

T['summary'] = function()
  local h = engine.hunks({ 'a', 'b', 'c' }, { 'A', 'B', 'c', 'd', 'e' })
  H.eq(engine.summary(h), { added = 2, changed = 2, removed = 0 })
end

T['async diff matches sync diff'] = function()
  local base, cur = {}, {}
  for i = 1, 5000 do
    base[i] = 'line ' .. i
    cur[i] = (i % 97 == 0) and ('changed ' .. i) or ('line ' .. i)
  end
  local got
  engine.hunks_async(base, cur, function(h)
    got = h
  end)
  vim.wait(5000, function()
    return got ~= nil
  end)
  H.eq(got, engine.hunks(base, cur))
end

return T
