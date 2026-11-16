-- `:P4` argument completion (complete.lua): changelists from known state, depot paths and
-- users from p4 (cached, with a wait limit), flags. Fake p4.
local H = require('tests.helpers')
local T = MiniTest.new_set()

local child, root

local function rules(extra)
  local out = vim.list_extend({}, extra or {})
  vim.list_extend(out, {
    { match = '^dirs //%*', records = { { dir = '//depot' }, { dir = '//team' } } },
    {
      match = '^dirs //depot/%*',
      records = { { dir = '//depot/main' }, { dir = '//depot/sp dir' } },
    },
    {
      match = '^files %-e //depot/%*',
      records = { { depotFile = '//depot/README' }, { depotFile = '//depot/a b.txt' } },
    },
    { match = '^users', records = { { User = 'alice' }, { User = 'bob' } } },
    { match = '^fstat', records = { { depotFile = '//depot/a.c', headRev = '1', haveRev = '1' } } },
    { match = '.', records = { { serverVersion = 'x' } } },
  })
  return out
end

local function setup(extra)
  root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(root .. '/a.c', 'x')
  child = H.child({ fake = { rules = rules(extra) }, env = { P4CONFIG = '.p4config' } })
  child.cmd('edit ' .. root .. '/a.c')
  H.eq(H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']]), true)
  H.wait_idle(child)
end

local function complete(line)
  return child.lua_get(('vim.fn.getcompletion(%q, "cmdline")'):format(line))
end

local function calls(pat)
  return #H.calls_matching(child.fake.log, pat)
end

T['complete'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['complete']['changelists come from what the plugin knows, with default / new where valid'] = function()
  setup()
  child.lua([[
    local ws = require('perforated').workspace()
    ws.pending_kept = { stamp = { t = 0, gen = 0 }, records = {
      { change = '12', desc = 'a' }, { change = '30', desc = 'b', shelved = '' },
    } }
    ws.opened = { ['//depot/a.c'] = { depotFile = '//depot/a.c', change = '41' },
                  ['//depot/b.c'] = { depotFile = '//depot/b.c', change = 'default' } }
  ]])
  local before = #H.calls(child.fake.log)
  H.eq(complete('P4 describe '), { 'default', '41', '30', '12' })
  H.eq(complete('P4 submit 3'), { '30' })
  H.eq(complete('P4 change '), { 'new', '41', '30', '12' })
  H.eq(complete('P4 change -'), { '-d' })
  H.eq(complete('P4 change -d '), { 'new', '41', '30', '12' })
  H.eq(complete('P4 edit -c '), { 'default', '41', '30', '12' })
  -- unshelve: changelists with a shelf; its -c target: any pending one or default
  H.eq(complete('P4 unshelve '), { '30' })
  H.eq(complete('P4 unshelve 30 -c '), { 'default', '41', '30', '12' })
  H.eq(complete('P4 integrate '), {}) -- no recent submits known (the client view wasn't open)
  H.eq(#H.calls(child.fake.log), before) -- no p4 call for any of it
end

T['complete']['depot paths: dirs and files, spaces escaped, kept for the next <Tab>'] = function()
  setup()
  H.eq(complete('P4 filelog //'), { '//depot/', '//team/' })
  H.eq(complete('P4 filelog //depot/'), {
    '//depot/README',
    '//depot/a\\ b.txt',
    '//depot/main/',
    '//depot/sp\\ dir/',
  })
  H.eq(complete('P4 sync //depot/sp\\ '), { '//depot/sp\\ dir/' })
  H.eq(complete('P4 filelog //depot/m'), { '//depot/main/' })
  H.eq(calls('dirs //depot/'), 1) -- the same directory: asked once
  H.eq(calls('files -e //depot/'), 1)
end

T['complete']['a slow p4: <Tab> waits at most complete.wait, the next one has the answer'] = function()
  setup({
    {
      match = '^dirs //depot/%*',
      sleep = 1.5,
      records = { { dir = '//depot/main' } },
    },
  })
  local t0 = vim.uv.hrtime()
  H.eq(complete('P4 filelog //depot/'), {})
  local ms = (vim.uv.hrtime() - t0) / 1e6
  H.eq(ms < 1000, true) -- 300 ms wait, plus the RPC round trip
  H.eq(ms >= 250, true)
  -- the call kept running: once it answered, the next <Tab> has it without asking again
  H.eq(H.wait(child, [[require('perforated.complete')._pending_count() == 0]], 5000), true)
  local got = complete('P4 filelog //depot/')
  H.eq(vim.tbl_contains(got, '//depot/main/'), true)
  H.eq(calls('dirs //depot/'), 1)
end

T['complete']['offline: no p4 call; users once per connection; flags'] = function()
  setup()
  H.eq(complete('P4 changes -u '), { 'alice', 'bob' })
  H.eq(complete('P4 changes -u b'), { 'bob' })
  H.eq(calls('users'), 1)
  H.eq(complete('P4 changes -'), { '-u', '-m' })
  H.eq(complete('P4 revert -'), { '-a' })
  child.lua([[require('perforated').workspace().conn:_set('offline', 'gone')]])
  local before = #H.calls(child.fake.log)
  H.eq(complete('P4 filelog //team/'), {})
  H.eq(#H.calls(child.fake.log), before)
end

return T
