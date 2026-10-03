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
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
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
  H.record_busy(child)
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
  -- Each step showed a busy pop-up, closed when p4 was done.
  H.eq(child.lua_get('_G.busy'), {
    { msg = ('Shelving CL %s…'):format(cl), open = false },
    { msg = ('Shelving CL %s…'):format(cl), open = false },
    { msg = ('Unshelving CL %s…'):format(cl), open = false },
    { msg = ('Deleting shelved files of CL %s…'):format(cl), open = false },
  })
end

T['m4']['shelf vs workspace after a re-shelve shows the new shelved content'] = function()
  setup()
  local cl = new_change('reshelve')
  p4({ 'edit', '-c', cl, root .. '/main/b.txt' })
  H.write(root .. '/main/b.txt', 'b2\n')
  p4({ 'shelve', '-c', cl })
  H.write(root .. '/main/b.txt', 'b2 local\n')
  local spec = '//depot/main/b.txt@=' .. cl
  local function shelved_side()
    child.lua(
      ([[require('perforated.diff.tab').open_shelf_vs_workspace(require('perforated').workspace(), %q)]]):format(
        cl
      )
    )
    wait(
      ('vim.fn.bufnr(%q) > 0 and vim.b[vim.fn.bufnr(%q)].perforated_loaded == true'):format(
        'perforated://' .. spec,
        'perforated://' .. spec
      )
    )
  end
  local lines = ('vim.api.nvim_buf_get_lines(vim.fn.bufnr(%q), 0, -1, false)'):format(
    'perforated://' .. spec
  )
  shelved_side()
  H.eq(child.lua_get(lines), { 'b2' })
  -- The shelf on the left, the workspace file on the right, each named in its header.
  local wins = child.api.nvim_tabpage_list_wins(0)
  H.eq(#wins, 3) -- panel + pair
  local bar = function(w)
    return child.api.nvim_get_option_value('winbar', { win = w })
  end
  H.eq(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(wins[2])), 'perforated://' .. spec)
  H.neq(bar(wins[2]):find('@=' .. cl .. ' (shelved)', 1, true), nil)
  H.eq(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(wins[3])), root .. '/main/b.txt')
  H.neq(bar(wins[3]):find(' main/b.txt ', 1, true), nil)
  H.neq(bar(wins[3]):find('(workspace)', 1, true), nil)
  child.cmd('tabclose')

  -- Re-shelve, replacing the shelf (what the shelve action's "replace" does).
  H.write(root .. '/main/b.txt', 'b3\n')
  p4({ 'shelve', '-f', '-c', cl })
  H.write(root .. '/main/b.txt', 'b3 local\n')
  shelved_side()
  wait(('vim.deep_equal(%s, { "b3" })'):format(lines))
end

local function changes_pending()
  return p4({ 'changes', '-s', 'pending' })
end

T['m4']['delete changelist: files move to default, shelf deleted, CL gone'] = function()
  setup()
  local cl = new_change('doomed')
  p4({ 'edit', '-c', cl, root .. '/main/b.txt' })
  H.write(root .. '/main/b.txt', 'b2\n')
  p4({ 'shelve', '-c', cl })
  child.lua(
    [[_G.confirm_msg = nil; require('perforated.ui.prompt').confirm = function(msg) _G.confirm_msg = msg; return 1 end]]
  )
  H.record_busy(child)
  child.cmd('P4 change -d ' .. cl)
  wait('_G.confirm_msg ~= nil')
  H.neq(child.lua_get('_G.confirm_msg'):find('1 opened file', 1, true), nil)
  H.neq(child.lua_get('_G.confirm_msg'):find('1 shelved file', 1, true), nil)
  H.eq(
    vim.wait(10000, function()
      return not changes_pending():find('doomed', 1, true)
    end, 100),
    true
  )
  -- "Deleting CL N…" from the confirmation until it's done.
  wait(('vim.deep_equal(_G.busy, { { msg = "Deleting CL %s…", open = false } })'):format(cl))
  H.eq(changes_pending():find('doomed', 1, true), nil)
  H.eq(opened()['//depot/main/b.txt'], { action = 'edit', change = 'default' })
  H.eq(table.concat(vim.fn.readfile(root .. '/main/b.txt'), '\n'), 'b2') -- edits kept
end

T['m4']['delete changelist: revert choice, empty CL, default refused'] = function()
  setup()
  local cl = new_change('revert me')
  p4({ 'edit', '-c', cl, root .. '/main/b.txt' })
  H.write(root .. '/main/b.txt', 'b2\n')
  child.lua([[require('perforated.ui.prompt').confirm = function() return 2 end]]) -- "Revert them"
  child.lua(
    ([[require('perforated.ops').delete_change(require('perforated').workspace(), %q, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r == true')
  H.eq(opened()['//depot/main/b.txt'], nil)
  H.eq(table.concat(vim.fn.readfile(root .. '/main/b.txt'), '\n'), 'b1')
  local empty = new_change('empty one')
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end; _G.r = nil]])
  child.lua(
    ([[require('perforated.ops').delete_change(require('perforated').workspace(), %q, function(ok) _G.r = ok end)]]):format(
      empty
    )
  )
  wait('_G.r == true')
  H.eq(changes_pending():find('empty one', 1, true), nil)
  child.lua(
    [[_G.r = nil; require('perforated.ops').delete_change(require('perforated').workspace(), 'default', function(ok) _G.r = ok end)]]
  )
  wait('_G.r == false')
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
  -- every sync is confirmed: "Cancel" runs nothing
  child.lua(
    [[require('perforated.ui.prompt').confirm = function(msg) _G.asked = msg; return 3 end]]
  ) -- Sync/Preview/Cancel
  child.lua([[require('perforated.core.log').clear(); _G.r = nil]])
  child.cmd('P4 sync')
  H.eq(child.lua_get('_G.asked'), 'Sync the whole workspace?')
  child.cmd('P4 sync @1')
  H.eq(child.lua_get('_G.asked'), 'Sync the whole workspace to @1?')
  H.eq(H.wait(child, 'false', 500), false)
  H.eq(
    #child.lua_get(
      [[vim.tbl_filter(function(e) return vim.tbl_contains(e.argv, 'sync') end, require('perforated.core.log').entries())]]
    ),
    0
  )
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
  bob_submits('main/a.txt', 'l1\nfrom bob\nl3\nl4\nl5\n')
  child.lua(
    [[require('perforated.ops').sync(require('perforated').workspace(), {}, function(ok) _G.r = ok end)]]
  )
  wait('_G.r == true')
  wait([[vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == 'from bob']])
  wait([[(require('perforated.buffer').get() or {}).rec.haveRev == '2']])
  H.eq(child.bo.modified, false)
  H.eq(child.lua_get([[#require('perforated.jobs').list()]]), 0)

  -- Preview on request: `sync -n`, then the question again with the counts (cancelled here)
  child.lua([[
    _G.asks = {}
    require('perforated.ui.prompt').confirm = function(msg) table.insert(_G.asks, msg); return 2 end -- Preview, then Cancel
    _G.r = nil
  ]])
  child.cmd('P4 sync @1')
  wait('#_G.asks == 2')
  H.neq(child.lua_get('_G.asks[2]'):find('Preview: 1 updated', 1, true), nil)
  H.eq(child.api.nvim_buf_get_lines(0, 1, 2, false)[1], 'from bob') -- nothing synced

  -- g@ on a submitted changelist in the client view: the workspace goes back to CL 1
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
  child.cmd('P4')
  -- Sections draw as their queries answer: wait for the Sync CL and Recent submitted.
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Sync CL: 2', 1, true) ~= nil
      and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('\n +CL 1 ') ~= nil]]
  )
  local row
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find('CL 1', 1, true) and not l:find('Sync CL', 1, true) then
      row = i
    end
  end
  child.api.nvim_win_set_cursor(0, { row, 0 })
  child.type_keys('g@')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Sync CL: 1', 1, true) ~= nil]]
  )
  H.eq(table.concat(vim.fn.readfile(root .. '/main/a.txt'), '\n'), 'l1\nl2\nl3\nl4\nl5')

  -- :P4 sync @ with no number: pick a changelist
  child.lua(
    [[vim.ui.select = function(items, _, cb) for _, c in ipairs(items) do if c.change == '2' then return cb(c) end end end]]
  )
  child.cmd('P4 sync @')
  H.eq(
    vim.wait(10000, function()
      return table.concat(vim.fn.readfile(root .. '/main/a.txt'), '\n'):find('from bob', 1, true)
        ~= nil
    end, 100),
    true
  )
end

T['m4']['sync: every unresolved file in quickfix, then the resolve prompt'] = function()
  setup()
  -- b.txt: already unresolved before this sync (synced outside the plugin)
  p4({ 'edit', root .. '/main/b.txt' })
  bob_submits('main/b.txt', 'bob b\n')
  p4({ 'sync', root .. '/main/b.txt' })
  -- a.txt: opened here, bob changes another line → this sync reports "must resolve"
  child.cmd('P4 edit')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  bob_submits('main/a.txt', 'l1\nl2\nl3\nl4\nbob5\n')
  child.lua_notify(
    [[require('perforated.ops').sync(require('perforated').workspace(), {}, function(ok) _G.r = ok end)]]
  )
  vim.uv.sleep(3000) -- the "Resolve now?" menu waits for a key (no RPC meanwhile)
  child.type_keys('l') -- later
  wait('_G.r == true')
  local qf = child.lua_get(
    [[vim.tbl_map(function(e) return vim.api.nvim_buf_get_name(e.bufnr) end, vim.fn.getqflist())]]
  )
  table.sort(qf)
  H.eq(qf, { root .. '/main/a.txt', root .. '/main/b.txt' })
  -- Each entry says R resolves it.
  child.cmd('copen')
  H.eq(
    vim.tbl_map(function(l)
      return vim.endswith(l, ' · R resolves')
    end, child.api.nvim_buf_get_lines(0, 0, -1, false)),
    { true, true }
  )
  -- R on an entry resolves it (clean merge for a.txt) and the entry leaves the list.
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys('R')
  H.eq(
    vim.wait(10000, function()
      return p4({ '-ztag', 'fstat', '-Ru', root .. '/main/a.txt' }) == ''
    end, 100),
    true
  )
  wait([[#vim.fn.getqflist() == 1]])
  -- Resolved elsewhere (here: outside the plugin, then any change event): the list follows.
  p4({ 'resolve', '-ay', root .. '/main/b.txt' })
  child.lua([[require('perforated.core.events').emit('Changed', {})]])
  wait([[#vim.fn.getqflist() == 0]])
  H.neq(child.lua_get([[vim.fn.getqflist({ title = 1 }).title]]):find('all resolved$'), nil)
  -- Empty now: its window closes (it would keep the focus and the space).
  wait([[vim.fn.getqflist({ winid = 0 }).winid == 0]])
end

T['m4']['reconcile scans only the configured paths; p changes them'] = function()
  setup({ client_view = { reconcile = { paths = { 'team' } } } })
  H.write(root .. '/team/new.txt', 'x\n')
  H.write(root .. '/other/noise.txt', 'y\n')
  child.cmd('P4')
  wait(
    [[require('perforated.views.client')._get(require('perforated').workspace().key).data ~= nil]]
  )
  local function goto_line(text)
    for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find(text, 1, true) then
        child.api.nvim_win_set_cursor(0, { i, 0 })
        return l
      end
    end
  end
  H.neq(goto_line('Workspace reconcile'):find('team', 1, true), nil)
  child.type_keys('l')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('new.txt', 1, true) ~= nil]]
  )
  H.eq(
    table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('noise.txt', 1, true),
    nil
  )
  -- r scans again (a finished scan isn't repeated by expanding)
  H.write(root .. '/team/newer.txt', 'z\n')
  goto_line('Workspace reconcile')
  child.type_keys('r')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('newer.txt', 1, true) ~= nil]]
  )
  -- p with an empty answer: the whole client
  child.lua([[require('perforated.ui.prompt').input = function(_, cb) cb('') end]])
  goto_line('Workspace reconcile')
  child.type_keys('p')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('noise.txt', 1, true) ~= nil]]
  )
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
  -- Never silent: a job pop-up when it starts, and a warning with the outcome.
  local msgs = child.lua_get([[vim.tbl_map(function(t) return t.title .. ': ' .. t.lines[1] end,
    require('perforated.ui.toast').history())]])
  H.eq(
    msgs[#msgs - 1],
    'Perforce: p4: resolve workspace…  (:P4 jobs to watch, :P4 cancel to stop)'
  )
  H.neq(
    msgs[#msgs]:find(
      '^Perforce: warning: p4: 1 file%(s%) left unresolved %(quickfix%): merge tool exited with 1'
    ),
    nil
  )
end

T['m4'][':P4 reopen moves the current file to another changelist'] = function()
  setup()
  local cl = new_change('target')
  child.cmd('P4 edit')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.cmd('P4 reopen -c ' .. cl)
  H.eq(
    vim.wait(10000, function()
      return (opened()['//depot/main/a.txt'] or {}).change == cl
    end, 100),
    true
  )
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

T['m4']["sync: a writable file p4 can't clobber goes to quickfix, not the synced count"] = function()
  setup()
  bob_submits('main/b.txt', 'bob b\n')
  vim.uv.fs_chmod(root .. '/main/b.txt', tonumber('644', 8))
  child.lua(
    [[_G.r = nil
    require('perforated.ops').sync(require('perforated').workspace(), {}, function(ok) _G.r = ok end)]]
  )
  wait('_G.r ~= nil')
  local qf = child.lua_get(
    [[vim.tbl_map(function(e) return vim.api.nvim_buf_get_name(e.bufnr) .. ' ' .. e.text end, vim.fn.getqflist())]]
  )
  H.eq(#qf, 1)
  H.neq(qf[1]:find(root .. '/main/b.txt', 1, true), nil)
  H.neq(qf[1]:find("can't clobber", 1, true), nil)
  H.eq(table.concat(vim.fn.readfile(root .. '/main/b.txt'), '\n'), 'b1')
end

T['m4']['file arguments: globs expand to every match; p4 wildcards in names are escaped'] = function()
  setup()
  H.eq(
    child.lua_get([[require('perforated.p4').escape('/w/i@2x#1%*.png')]]),
    '/w/i%402x%231%25%2A.png'
  )
  H.eq(
    child.lua_get([[require('perforated.p4').escape('//depot/i%402x.png')]]),
    '//depot/i%402x.png'
  )
  child.cmd('P4 edit ' .. root .. '/main/*.txt')
  H.eq(
    vim.wait(10000, function()
      local o = opened()
      return o['//depot/main/a.txt'] ~= nil and o['//depot/main/b.txt'] ~= nil
    end, 100),
    true
  )
  -- a file opened for add: move reports success (p4 answers with action "add")
  H.write(root .. '/main/n.txt', 'new\n')
  p4({ 'add', root .. '/main/n.txt' })
  child.cmd('edit ' .. root .. '/main/n.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.lua([[_G.r = nil]])
  child.lua(
    ([[require('perforated.ops').move(0, %q, function(ok) _G.r = ok end)]]):format(
      root .. '/main/m.txt'
    )
  )
  wait('_G.r ~= nil')
  H.eq(child.lua_get('_G.r'), true)
  H.eq(opened()['//depot/main/m.txt'].action, 'add')
  H.eq(child.api.nvim_buf_get_name(0), root .. '/main/m.txt')
end

T['m4']['a file with p4 wildcards in its name: add, attach, check out, revert'] = function()
  setup()
  local path = root .. '/main/icon@2x.txt'
  H.write(path, 'px\n')
  child.cmd('edit ' .. vim.fn.fnameescape(path))
  wait([[(require('perforated.buffer').get() or {}).status == 'new']])
  child.lua(
    [[require('perforated.checkout').add(require('perforated').workspace(), { vim.api.nvim_buf_get_name(0) })]]
  )
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  p4({ 'submit', '-d', 'icon' })
  child.lua([[require('perforated.buffer').refresh(vim.api.nvim_get_current_buf())]])
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.lua(
    [[require('perforated.checkout').edit(require('perforated').workspace(), { vim.api.nvim_buf_get_name(0) })]]
  )
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/main/icon%402x.txt'].action, 'edit')
  child.lua(
    [[require('perforated.checkout').revert(require('perforated').workspace(), { vim.api.nvim_buf_get_name(0) })]]
  )
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
end

T['m4']["delete changelist: another client's CL with opened files is refused, its shelf kept"] = function()
  setup({ change = { allow_force = true } })
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  local out = server:p4({ 'change', '-i' }, {
    client = 'bob_ws',
    user = 'bob',
    cwd = bob,
    stdin = 'Change: new\nDescription:\n\tbob work\n',
  }).stdout
  local cl = out:match('Change (%d+) created')
  server:p4(
    { 'edit', '-c', cl, bob .. '/main/b.txt' },
    { client = 'bob_ws', user = 'bob', cwd = bob }
  )
  server:p4({ 'shelve', '-c', cl }, { client = 'bob_ws', user = 'bob', cwd = bob })
  child.lua(
    ([[_G.r = nil
    require('perforated.ops').delete_change(require('perforated').workspace(), %q, function(ok) _G.r = ok end)]]):format(
      cl
    )
  )
  wait('_G.r ~= nil')
  H.eq(child.lua_get('_G.r'), false)
  H.neq(p4({ 'describe', '-S', '-s', cl }):find('//depot/main/b.txt', 1, true), nil)
end

T['m4']['integrate: preview, confirm, integrate into a branch, resolve'] = function()
  setup()
  -- branch main → rel, then a fix on main to cherry-pick
  p4({ 'integrate', '//depot/main/...', '//depot/rel/...' })
  p4({ 'submit', '-d', 'branch rel' })
  bob_submits('main/b.txt', 'b-fix\n', 'fix b')
  local fix = server:p4({ 'changes', '-m1', '//depot/main/b.txt' }).stdout:match('Change (%d+)')
  child.lua([[
    require('perforated.ui.prompt').input = function(_, cb) cb('//depot/rel/...') end
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
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
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
