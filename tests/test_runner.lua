local H = require('tests.helpers')
local T = MiniTest.new_set()

local child

local function run(spec)
  child.lua(
    [[
    local spec = ...
    _G.res = nil
    require('perforated.core.runner').run(spec, function(r) _G.res = r end)
  ]],
    { spec }
  )
  H.eq(H.wait(child, '_G.res ~= nil', 10000), true)
  return child.lua_get('_G.res')
end

T['runner'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = H.child({
        fake = {
          rules = {
            {
              match = '^fstat',
              records = {
                { depotFile = '//depot/a.txt', haveRev = '1' },
                { data = 'b - no such file(s).\n', generic = 17, severity = 2 },
              },
            },
            {
              match = '^opened',
              records = {
                {
                  data = 'Perforce password (P4PASSWD) invalid or unset.\n',
                  generic = 36,
                  severity = 3,
                },
              },
            },
            { match = '^changes', hang = true },
            {
              match = '^describe',
              records = { { change = '1' } },
              kill = 'sigkill',
            },
            { match = '^set', stdout = 'P4PORT=1666\n' },
          },
        },
        env = { P4DIFF = 'meld', P4MERGE = 'p4merge', P4PAGER = 'less', P4EDITOR = 'vim' },
      })
      child.cwd = child.home
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['runner']['a process killed by a signal is not ok'] = function()
  local r = run({ args = { 'describe', '1' }, cwd = child.cwd })
  H.eq(r.ok, false)
  H.eq(r.code, 128 + 9)
end

T['runner']['parses JSON records and warnings'] = function()
  local r = run({ args = { 'fstat', 'a', 'b' }, cwd = child.cwd })
  H.eq(r.ok, true)
  H.eq(r.records, { { depotFile = '//depot/a.txt', haveRev = '1' } })
  H.eq(r.warnings, { 'b - no such file(s).' })
  local calls = H.calls(child.fake.log)
  H.eq(calls[1].argv, { '-Mj', '-ztag', 'fstat', 'a', 'b' })
end

T['runner']['keep_records = false: records only stream to on_record; messages are kept'] = function()
  child.lua([[
    _G.res, _G.seen = nil, {}
    require('perforated.core.runner').run({
      args = { 'fstat', 'a', 'b' }, cwd = vim.uv.cwd(), keep_records = false,
      on_record = function(rec) table.insert(_G.seen, rec.depotFile or rec.data) end,
    }, function(r) _G.res = r end)
  ]])
  H.eq(H.wait(child, '_G.res ~= nil', 10000), true)
  local r = child.lua_get('{ _G.res.records, _G.res.count, _G.res.warnings, #_G.res.all, _G.seen }')
  H.eq(r, { {}, 1, { 'b - no such file(s).' }, 1, { '//depot/a.txt', 'b - no such file(s).\n' } })
  -- kept by default, and counted the same
  H.eq(run({ args = { 'fstat', 'a', 'b' }, cwd = child.cwd }).count, 1)
end

T['runner']['severity >= 3 fails even with exit 0'] = function()
  local r = run({ args = { 'opened' }, cwd = child.cwd })
  H.eq(r.ok, false)
  H.eq(r.errors, { 'Perforce password (P4PASSWD) invalid or unset.' })
end

T['runner']['stdin list feeds -x -'] = function()
  run({ args = { '-x', '-', 'fstat' }, cwd = child.cwd, stdin = { '/w/a b.txt', '/w/c.txt' } })
  H.eq(H.calls(child.fake.log)[1].stdin, '/w/a b.txt\n/w/c.txt\n')
end

T['runner']['internal calls neutralise tool variables and set PWD'] = function()
  run({ args = { 'fstat', 'a' }, cwd = child.cwd })
  local env = H.calls(child.fake.log)[1].env
  H.eq(env.P4DIFF, 'false')
  H.eq(env.P4MERGE, 'false')
  H.eq(env.P4EDITOR, 'false')
  H.eq(env.P4PAGER, vim.NIL)
  H.eq(env.PWD, child.cwd)
  H.eq(H.calls(child.fake.log)[1].cwd, child.cwd)
end

T['runner']['user-mode calls keep the user environment'] = function()
  run({ args = { 'fstat', 'a' }, cwd = child.cwd, env_mode = 'user' })
  local env = H.calls(child.fake.log)[1].env
  H.eq(env.P4DIFF, 'meld')
  H.eq(env.P4MERGE, 'p4merge')
  H.eq(env.P4PAGER, 'less')
end

T['runner']['timeout kills a hung process'] = function()
  local t0 = vim.uv.hrtime()
  local r = run({ args = { 'changes' }, cwd = child.cwd, timeout = 300 })
  H.eq(r.timed_out, true)
  H.eq(r.ok, false)
  H.eq(r.err, 'timed out after 300ms') -- no p4 message: callers still have one line to show
  H.expect.no_equality((vim.uv.hrtime() - t0) / 1e6 > 5000, true)
end

T['runner']['cut: a run stopped before p4 finished, or failing without a message'] = function()
  local cut = function(spec)
    run(spec)
    return child.lua_get([[require('perforated.core.runner').cut(_G.res)]])
  end
  H.eq(cut({ args = { 'changes' }, cwd = child.cwd, timeout = 300 }), true) -- timed out
  H.eq(cut({ args = { 'describe', '1' }, cwd = child.cwd }), true) -- killed by a signal
  H.eq(cut({ args = { 'fstat', 'a', 'b' }, cwd = child.cwd }), false) -- an answer
  H.eq(cut({ args = { 'opened' }, cwd = child.cwd }), false) -- p4 said why it failed
end

T['runner']['untagged returns stdout'] = function()
  local r = run({ args = { 'set', '-q' }, cwd = child.cwd, tagged = false })
  H.eq(r.stdout, 'P4PORT=1666\n')
  H.eq(H.calls(child.fake.log)[1].argv, { 'set', '-q' })
end

T['runner']['spawn failure is reported asynchronously'] = function()
  local r = run({ args = { 'info' }, cwd = child.cwd, bin = '/nonexistent/p4' })
  H.eq(r.ok, false)
  H.eq(r.code, -1)
end

T['runner']['every call is logged'] = function()
  run({ args = { 'fstat', 'a' }, cwd = child.cwd })
  run({ args = { 'opened' }, cwd = child.cwd })
  local entries = child.lua_get([[vim.tbl_map(function(e) return { argv = e.argv, err = e.err } end,
    require('perforated.core.log').entries())]])
  H.eq(#entries, 2)
  H.eq(entries[2].err, 'Perforce password (P4PASSWD) invalid or unset.')
  local text = child.lua_get(
    [[require('perforated.core.log').format(require('perforated.core.log').entries()[1])]]
  )
  H.expect.no_equality(text:find('fstat a', 1, true), nil)
end

return T
