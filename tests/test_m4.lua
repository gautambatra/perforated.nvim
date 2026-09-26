-- M4: shelve / unshelve, submit, sync (+ monitoring and cancel), resolve, delete, move,
-- integrate. Real p4d unless noted.
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root, bob

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
end

local function p4(args, opts)
  opts = vim.tbl_extend('force', { client = 'alice_ws', cwd = root }, opts or {})
  return server:p4(args, opts).stdout
end

--- Bob changes a file and submits it.
local function bob_submits(rel, content, desc)
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4({ 'edit', bob .. '/' .. rel }, { client = 'bob_ws', user = 'bob', cwd = bob })
  H.write(bob .. '/' .. rel, content)
  server:p4({ 'submit', '-d', desc or 'bob' }, { client = 'bob_ws', user = 'bob', cwd = bob })
end

local function setup(extra_config)
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, {
    ['main/a.txt'] = 'l1\nl2\nl3\nl4\nl5\n',
    ['main/b.txt'] = 'b1\n',
  }, 'initial import')
  bob = server.dir .. '/bob'
  server:client('bob_ws', bob, 'bob')
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_deep_extend('force', {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      checkout = { prompt = false },
      diff = { external_terminal = false },
      merge = { tool = H.root .. '/tests/bin/fake-merge' },
    }, extra_config or {}),
  })
  child.o.lines, child.o.columns = 40, 160
  child.lua([[vim.fn.confirm = function() return 1 end]])
  child.cmd('edit ' .. root .. '/main/a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
end

local function new_change(desc)
  local out = p4({ 'change', '-i' }, { stdin = 'Change: new\nDescription:\n\t' .. desc .. '\n' })
  return out:match('Change (%d+) created')
end

local function opened()
  local out = p4({ '-ztag', 'opened' })
  local files = {}
  for depot, action, change in
    out:gmatch('%.%.%. depotFile (%S+).-%.%.%. action (%S+).-%.%.%. change (%S+)')
  do
    files[depot] = { action = action, change = change }
  end
  return files
end

local function status()
  return child.lua_get([[(require('perforated.buffer').get() or {}).status]])
end

T['m4'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
    end,
    post_case = function()
      if child then
        child.stop()
      end
    end,
  },
})

T['m4']['shelve (replace after confirm), delete shelved, unshelve into the same CL'] = function()
  setup()
  local cl = new_change('shelf work')
  p4({ 'edit', '-c', cl, root .. '/main/b.txt' })
  H.write(root .. '/main/b.txt', 'b2\n')
  child.lua(
    ([[require('perforated.ops').shelve(require('perforated').workspace(), %q, nil, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == true')
  H.neq(p4({ 'describe', '-S', '-s', cl }):find('//depot/main/b.txt#1', 1, true), nil)
  -- again: the shelf exists → confirmation (stubbed yes) → -f replaces it
  H.write(root .. '/main/b.txt', 'b3\n')
  child.lua([[_G.r = nil]])
  child.lua(
    ([[require('perforated.ops').shelve(require('perforated').workspace(), %q, nil, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == true')
  H.eq(p4({ 'print', '-q', '//depot/main/b.txt@=' .. cl }), 'b3\n')
  -- revert the workspace copy, unshelve it back (our own pending CL is the target)
  p4({ 'revert', root .. '/main/b.txt' })
  child.lua([[_G.r = nil]])
  child.lua(
    ([[require('perforated.ops').unshelve(require('perforated').workspace(), %q, nil, nil, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == true')
  H.eq(opened()['//depot/main/b.txt'], { action = 'edit', change = cl })
  H.eq(table.concat(vim.fn.readfile(root .. '/main/b.txt'), '\n'), 'b3')
  child.lua([[_G.r = nil]])
  child.lua(
    ([[require('perforated.ops').delete_shelved(require('perforated').workspace(), %q, nil, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == true')
  H.eq(p4({ 'describe', '-S', '-s', cl }):find('//depot/main/b.txt#', 1, true), nil)
end

T['m4']['submit: confirmation float, s submits; buffer state follows'] = function()
  setup()
  local cl = new_change('ship it')
  child.cmd('P4 edit -c ' .. cl)
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.lua([[vim.bo.readonly = false]])
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'changed' })
  child.cmd('write')
  child.lua_notify(
    ('require("perforated.ops").submit(require("perforated").workspace(), %q)'):format(cl)
  )
  vim.uv.sleep(1500) -- the float waits for a key (the child can't answer RPC meanwhile)
  child.type_keys('s')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.neq(p4({ 'changes', '-s', 'submitted' }):find('ship it', 1, true), nil)
  H.eq(child.lua_get([[require('perforated').workspace().sticky_cl]]), vim.NIL)
end

T['m4']['submit of an out-of-date file fails into quickfix'] = function()
  setup()
  local cl = new_change('late')
  child.cmd('P4 edit -c ' .. cl)
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  bob_submits('main/a.txt', 'l1\nbob\nl3\nl4\nl5\n')
  child.lua(
    ([[require('perforated.ops').run_submit(require('perforated').workspace(), %q, nil, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == false')
  local qf = child.fn.getqflist()
  H.eq(#qf >= 1, true)
  H.neq(qf[1].text:find('resolve', 1, true) or qf[1].text:find('sync', 1, true), nil)
end

T['m4']['sync reloads the buffer without prompting; state follows'] = function()
  setup()
  bob_submits('main/a.txt', 'l1\nfrom bob\nl3\nl4\nl5\n')
  child.lua(
    [[require('perforated.ops').sync(require('perforated').workspace(), {}, function(ok) _G.r = ok end)]]
  )
  wait('_G.r == true')
  wait([[vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == 'from bob']])
  wait([[(require('perforated.buffer').get() or {}).rec.haveRev == '2']])
  H.eq(child.bo.modified, false)
  H.eq(child.lua_get([[#require('perforated.jobs').list()]]), 0)
end

T['m4']['resolve: -am takes clean merges; conflicts go to the merge tool'] = function()
  setup()
  child.cmd('P4 edit')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.lua([[vim.bo.readonly = false]])
  -- local edit of line 5; bob edits line 2 (clean) → -am resolves
  child.api.nvim_buf_set_lines(0, 4, 5, false, { 'mine5' })
  child.cmd('write')
  bob_submits('main/a.txt', 'l1\nbob2\nl3\nl4\nl5\n')
  p4({ 'sync' })
  child.lua(
    [[require('perforated.resolve').run(require('perforated').workspace(), nil, function(n, left) _G.r = { n, left } end)]]
  )
  wait('_G.r ~= nil')
  H.eq(child.lua_get('_G.r'), { 1, 0 })
  H.eq(p4({ '-ztag', 'fstat', '-Ru', root .. '/main/a.txt' }), '')
  -- conflict on line 1: the tool writes the result and exits 0
  wait([[vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == 'bob2']]) -- reloaded after -am
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'mine1' })
  child.cmd('write')
  bob_submits('main/a.txt', 'bob1\nbob2\nl3\nl4\nl5\n')
  p4({ 'sync' })
  local result, log = server.dir .. '/result.txt', server.dir .. '/merge.log'
  H.write(result, 'merged1\nbob2\nl3\nl4\nmine5\n')
  child.lua(
    ([[require('perforated.config').set({ merge = { tool = 'FAKE_MERGE_RESULT=%s FAKE_MERGE_LOG=%s %s' } })]]):format(
      result,
      log,
      H.root .. '/tests/bin/fake-merge'
    )
  )
  child.lua(
    [[_G.r = nil; require('perforated.resolve').run(require('perforated').workspace(), nil, function(n, left) _G.r = { n, left } end)]]
  )
  wait('_G.r ~= nil')
  H.eq(child.lua_get('_G.r'), { 1, 0 })
  local args = vim.fn.readfile(log)
  H.eq(#args, 4)
  H.eq(args[1]:match('a%.txt%.base$') ~= nil, true) -- base, theirs, yours, merged
  H.eq(args[2]:match('a%.txt%.theirs$') ~= nil, true)
  H.eq(args[3], root .. '/main/a.txt')
  H.eq(child.api.nvim_buf_get_lines(0, 0, 1, false)[1], 'merged1')
  H.eq(p4({ '-ztag', 'fstat', '-Ru', root .. '/main/a.txt' }), '')
end

T['m4']['resolve: a cancelled merge leaves the file unresolved in quickfix'] = function()
  setup({ merge = { tool = 'FAKE_MERGE_EXIT=1 ' .. H.root .. '/tests/bin/fake-merge' } })
  child.cmd('P4 edit')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.lua([[vim.bo.readonly = false]])
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'mine1' })
  child.cmd('write')
  bob_submits('main/a.txt', 'bob1\nl2\nl3\nl4\nl5\n')
  p4({ 'sync' })
  child.lua(
    [[require('perforated.resolve').run(require('perforated').workspace(), nil, function(n, left) _G.r = { n, left } end)]]
  )
  wait('_G.r ~= nil')
  H.eq(child.lua_get('_G.r'), { 0, 1 })
  local qf = child.fn.getqflist()
  H.eq(#qf, 1)
  H.neq(qf[1].text:find('exited with 1', 1, true), nil)
  H.neq(p4({ '-ztag', 'fstat', '-Ru', root .. '/main/a.txt' }), '')
end

T['m4']['delete wipes the buffer; move renames the buffer and keeps it attached'] = function()
  setup()
  child.cmd('P4 move ' .. root .. '/main/renamed.txt')
  wait(([[vim.api.nvim_buf_get_name(0) == %q]]):format(root .. '/main/renamed.txt'))
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/main/renamed.txt'].action, 'move/add')
  H.eq(vim.fn.filereadable(root .. '/main/a.txt'), 0)
  child.cmd('edit ' .. root .. '/main/b.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  local b = child.api.nvim_get_current_buf()
  child.cmd('P4 delete')
  wait(('not vim.api.nvim_buf_is_valid(%d)'):format(b))
  H.eq(opened()['//depot/main/b.txt'].action, 'delete')
end

T['m4']['integrate: preview, confirm, integrate into a branch, resolve'] = function()
  setup()
  -- branch main → rel, then a fix on main to cherry-pick
  p4({ 'integrate', '//depot/main/...', '//depot/rel/...' })
  p4({ 'submit', '-d', 'branch rel' })
  bob_submits('main/b.txt', 'b-fix\n', 'fix b')
  local fix = server:p4({ 'changes', '-m1', '//depot/main/b.txt' }).stdout:match('Change (%d+)')
  child.lua([[
    vim.ui.input = function(_, cb) cb('//depot/rel/...') end
    vim.ui.select = function(items, _, cb) cb(items[1]) end -- default changelist
  ]])
  child.lua(
    ([[require('perforated.integrate').run(require('perforated').workspace(), %q, function(ok) _G.r = ok end)]]):format(
      fix
    )
  )
  wait('_G.r == true')
  H.eq(opened()['//depot/rel/b.txt'].action, 'integrate')
  H.eq(p4({ '-ztag', 'fstat', '-Ru', '//depot/rel/b.txt' }), '') -- resolved (clean)
  H.eq(table.concat(vim.fn.readfile(root .. '/rel/b.txt'), '\n'), 'b-fix')
end

-- Fake p4: a slow sync streams output; :P4 jobs shows it and :P4 cancel stops it.
T['sync monitoring'] = function()
  local r = H.tmp()
  H.write(r .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(r .. '/a.c', 'x')
  child = H.child({
    fake = {
      rules = {
        {
          match = '^info',
          records = { { clientName = 'ws1', clientRoot = r, userName = 'alice' } },
        },
        { match = '^set', stdout = 'P4CLIENT=ws1\n' },
        {
          match = '^sync',
          hang_after = true,
          records = {
            { depotFile = '//depot/a.c', clientFile = r .. '/a.c', action = 'updated', rev = '2' },
            { depotFile = '//depot/b.c', clientFile = r .. '/b.c', action = 'added', rev = '1' },
          },
        },
        { match = '.', records = {} },
      },
    },
    env = { P4CONFIG = '.p4config' },
    config = { p4 = H.fake_p4, poll = { interval = 0 }, startup_check = false },
  })
  child.cmd('edit ' .. r .. '/a.c')
  H.wait(child, [[(require('perforated.core.workspace').list()[1] or {}).settings ~= nil]], 10000)
  child.lua(
    [[require('perforated.ops').sync(require('perforated').workspace(), {}, function(ok) _G.r = ok end)]]
  )
  wait([[(require('perforated.jobs').list()[1] or {}).count == 2]])
  H.eq(child.lua_get([[require('perforated.jobs').list()[1].last]]), '//depot/b.c')
  child.cmd('P4 jobs')
  wait([[vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('2 file', 1, true) ~= nil]])
  child.type_keys('x') -- stop the job under the cursor
  wait('_G.r == false', 8000)
  H.eq(child.lua_get([[#require('perforated.jobs').list()]]), 0)
  child.stop()
end

return T
