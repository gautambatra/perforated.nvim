-- M2: client view, changelist editor, diff tab — against a real p4d.
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

local function setup()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files(
    'alice_ws',
    root,
    { ['a.txt'] = 'a1\n', ['b.txt'] = 'b1\n', ['c.txt'] = 'c1\n', ['d.txt'] = 'd1\n' },
    'initial import'
  )
  server:p4config(root, 'alice_ws')
  -- CL "Fix parser" with a.txt opened and shelved; b.txt opened in default; c.txt opened+stale.
  server:p4({ 'change', '-i' }, {
    client = 'alice_ws',
    cwd = root,
    stdin = 'Change: new\nDescription:\n\tFix parser\n\tsecond line\n',
  })
  server:p4({ 'edit', '-c', '2', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
  H.write(root .. '/a.txt', 'a2\n')
  server:p4({ 'shelve', '-c', '2' }, { client = 'alice_ws', cwd = root })
  server:p4({ 'edit', root .. '/b.txt', root .. '/c.txt' }, { client = 'alice_ws', cwd = root })
  -- bob submits c.txt → alice's c.txt is stale
  local bob = server.dir .. '/bob'
  server:client('bob_ws', bob, 'bob')
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4({ 'edit', bob .. '/c.txt' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  H.write(bob .. '/c.txt', 'c2\n')
  server:p4({ 'submit', '-d', 'bob changes c' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  -- untracked file for reconcile
  H.write(root .. '/new.txt', 'new\n')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      checkout = { prompt_grace = 0 },
    },
  })
  child.o.lines, child.o.columns = 40, 140
  child.cmd('edit ' .. root .. '/d.txt')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000)
end

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
end

local VIEW =
  [[require('perforated.views.client')._get(require('perforated').workspace(vim.fn.bufnr(%q)).key)]]

local function view_expr(root_path)
  return VIEW:format(root_path .. '/d.txt')
end

--- Open the client view and wait for its data.
local function open_view()
  child.cmd('P4')
  wait(('(%s or {}).data ~= nil and not (%s).loading'):format(view_expr(root), view_expr(root)))
end

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- Move the cursor to the first line containing `text`.
local function goto_line(text)
  for i, l in ipairs(lines()) do
    if l:find(text, 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error('line not found: ' .. text .. '\n' .. table.concat(lines(), '\n'))
end

local function has_line(text)
  for _, l in ipairs(lines()) do
    if l:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function opened()
  local out = server:p4({ '-ztag', 'opened' }, { client = 'alice_ws', cwd = root }).stdout
  local files = {}
  for depot, change in out:gmatch('%.%.%. depotFile (%S+).-%.%.%. change (%S+)') do
    files[depot] = change
  end
  return files
end

T['client view'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      setup()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['client view']['shows pending CLs, files, shelves, stale files, submitted, reconcile'] = function()
  open_view()
  H.eq(#child.api.nvim_list_tabpages(), 2)
  H.eq(has_line('Client alice_ws'), true)
  H.eq(has_line('Pending'), true)
  H.eq(has_line('default'), true)
  H.eq(has_line('CL 2  Fix parser'), true)
  H.eq(has_line('a.txt'), true)
  H.eq(has_line('Shelved (1)'), true)
  H.eq(has_line('stale'), true) -- c.txt
  H.eq(has_line('Needs attention'), true)
  H.eq(has_line('Recent submitted'), true)
  H.eq(has_line('initial import'), true)
  H.eq(has_line('Workspace reconcile'), true)
  -- The footer float shows the keys for the cursor's node.
  goto_line('b.txt')
  local footer = child.lua_get([[(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative == 'win' and c.focusable == false then
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1]
      end
    end
  end)()]])
  H.expect.no_equality(footer:find('d diff', 1, true), nil)
  H.expect.no_equality(footer:find('x revert', 1, true), nil)
end

T['client view']['h/l fold, and folds survive refresh'] = function()
  open_view()
  goto_line('CL 2  Fix parser')
  child.type_keys('h')
  H.eq(has_line('a.txt'), false)
  child.type_keys('gr')
  wait(('not (%s).loading'):format(view_expr(root)))
  vim.uv.sleep(200)
  H.eq(has_line('a.txt'), false)
  goto_line('CL 2  Fix parser')
  child.type_keys('l')
  H.eq(has_line('a.txt'), true)
end

T['client view']['x reverts the file under the cursor; view refreshes'] = function()
  open_view()
  child.lua([[vim.fn.confirm = function() return 1 end]])
  goto_line('b.txt')
  child.type_keys('x')
  wait(
    ([[not vim.tbl_contains(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), 'b.txt')
    and not table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), '\n'):find('b.txt', 1, true)]]):format(
      view_expr(root),
      view_expr(root)
    )
  )
  H.eq(opened()['//depot/b.txt'], nil)
end

T['client view']['M moves marked files to another changelist'] = function()
  open_view()
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.change == '2' then return cb(it) end end
  end]])
  goto_line('b.txt')
  child.type_keys('m')
  goto_line('c.txt')
  child.type_keys('m', 'M')
  H.eq(H.wait(child, 'false', 1500), false)
  local o = opened()
  H.eq(o['//depot/b.txt'], '2')
  H.eq(o['//depot/c.txt'], '2')
end

T['client view']['c creates a changelist from the description editor'] = function()
  open_view()
  child.type_keys('c')
  child.type_keys('Brand new work', '<C-s>')
  wait([[require('perforated').workspace() == nil or true]])
  H.eq(H.wait(child, 'false', 1500), false)
  local out =
    server:p4({ '-ztag', 'changes', '-s', 'pending' }, { client = 'alice_ws', cwd = root }).stdout
  H.expect.no_equality(out:find('Brand new work', 1, true), nil)
  wait(
    ('table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), "\\n"):find("Brand new work", 1, true) ~= nil'):format(
      view_expr(root)
    )
  )
end

T['client view']['C edits a pending description; only the Description field changes'] = function()
  open_view()
  goto_line('CL 2  Fix parser')
  child.type_keys('C')
  wait([[vim.bo.filetype == 'perforated-description']])
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'Fix parser', 'second line' })
  child.type_keys('ggA', ' (edited)', '<Esc>', ':w<CR>')
  wait([[vim.bo.filetype ~= 'perforated-description']])
  local spec = server:p4({ 'change', '-o', '2' }, { client = 'alice_ws', cwd = root }).stdout
  H.expect.no_equality(spec:find('Fix parser (edited)', 1, true), nil)
  H.expect.no_equality(spec:find('second line', 1, true), nil)
  H.expect.no_equality(spec:find('//depot/a.txt', 1, true), nil) -- files untouched
end

T['client view']['C on a submitted CL updates it with -u'] = function()
  open_view()
  goto_line('initial import')
  child.type_keys('C')
  wait([[vim.bo.filetype == 'perforated-description']])
  child.type_keys('ggA', ' v2', '<Esc>', '<C-s>')
  wait([[vim.bo.filetype ~= 'perforated-description']])
  local out =
    server:p4({ '-ztag', 'describe', '-s', '1' }, { client = 'alice_ws', cwd = root }).stdout
  H.expect.no_equality(out:find('initial import v2', 1, true), nil)
end

T['client view']['C is not offered on the default changelist'] = function()
  open_view()
  goto_line('default')
  child.type_keys('C')
  H.eq(child.bo.filetype, 'perforated')
  H.expect.no_equality(child.cmd_capture('messages'):find('does not apply here', 1, true), nil)
end

T['client view']['d on a shelved file diffs base vs shelf'] = function()
  open_view()
  goto_line('Shelved (1)')
  child.type_keys('l')
  goto_line('//depot/a.txt')
  child.type_keys('d')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  table.sort(names)
  H.eq(names, { 'perforated:////depot/a.txt#1', 'perforated:////depot/a.txt@=2' })
end

T['client view']['D opens the diff tab for a CL; <Tab> steps files'] = function()
  open_view()
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local wins = child.api.nvim_tabpage_list_wins(0)
  H.eq(#wins, 3) -- panel + pair
  local panel = child.api.nvim_buf_get_lines(0, 0, -1, false)
  H.expect.no_equality(table.concat(panel, '\n'):find('b.txt', 1, true), nil)
  H.expect.no_equality(table.concat(panel, '\n'):find('c.txt', 1, true), nil)
  local right_name = function()
    return child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(wins[3]))
  end
  local first = right_name()
  child.type_keys('<Tab>')
  H.neq(right_name(), first)
  child.type_keys('q')
  H.eq(#child.api.nvim_list_tabpages(), 2)
end

T['client view']['reconcile scans on expand; a opens found files'] = function()
  open_view()
  goto_line('Workspace reconcile')
  child.type_keys('l')
  wait(
    ('table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), "\\n"):find("new.txt", 1, true) ~= nil'):format(
      view_expr(root)
    )
  )
  goto_line('new.txt')
  child.type_keys('a')
  H.eq(H.wait(child, 'false', 1500), false)
  H.eq(opened()['//depot/new.txt'], 'default')
end

T['client view']['Q sends a CL to quickfix; <Space> menu lists only valid actions'] = function()
  open_view()
  goto_line('default')
  child.type_keys('Q')
  local qf = child.fn.getqflist()
  H.eq(#qf, 2)
  H.eq(child.fn.getqflist({ context = 1 }).context.kind, 'client_view')
  child.cmd('wincmd p')
  local valid = child.lua_get([[(function()
    local v = ]] .. view_expr(root) .. [[
    vim.api.nvim_set_current_win(vim.fn.bufwinid(v.buf))
    for i, l in ipairs(vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)) do
      if l:find('b.txt', 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
    end
    return vim.tbl_map(function(a) return a.id end, require('perforated.ui.keys').valid(v.actions, v.tree:node_at()))
  end)()]])
  H.eq(vim.tbl_contains(valid, 'diff'), true)
  H.eq(vim.tbl_contains(valid, 'revert'), true)
  H.eq(vim.tbl_contains(valid, 'edit_description'), false)
end

T['client view']['A switches to all my clients'] = function()
  local root2 = server.dir .. '/ws2'
  server:client('alice_ws2', root2)
  server:p4({ 'sync' }, { client = 'alice_ws2', cwd = root2 })
  server:p4({ 'edit', root2 .. '/d.txt' }, { client = 'alice_ws2', cwd = root2 })
  open_view()
  H.eq(has_line('@alice_ws2'), false)
  child.type_keys('A')
  wait(
    ('table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), "\\n"):find("@alice_ws2", 1, true) ~= nil'):format(
      view_expr(root)
    )
  )
  H.eq(has_line('[all my clients]'), true)
end

T['client view']['P4V keys are mapped; keys.p4v = false removes them'] = function()
  open_view()
  H.eq(child.lua_get([[vim.fn.maparg('<C-d>', 'n', false, true).buffer]]), 1)
  child.cmd('tabclose')
  child.lua([[require('perforated.config').set({ keys = { p4v = false } })]])
  child.cmd('bwipeout! ' .. child.lua_get(view_expr(root) .. '.buf'))
  open_view()
  H.eq(child.fn.maparg('<C-d>', 'n'), '')
  H.eq(child.lua_get([[vim.fn.maparg('d', 'n', false, true).buffer]]), 1)
end

T['change command'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      setup()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['change command'][':P4 change on a file in the default CL explains; :P4 change 2 edits'] = function()
  child.cmd('edit ' .. root .. '/b.txt')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.cmd('P4 change')
  H.expect.no_equality(
    child.cmd_capture('messages'):find('default changelist has no description', 1, true),
    nil
  )
  child.cmd('P4 change 2')
  wait([[vim.bo.filetype == 'perforated-description']])
  H.eq(child.api.nvim_buf_get_lines(0, 0, 1, false), { 'Fix parser' })
end

T['change command']['check-out "n" uses the description editor'] = function()
  child.cmd('edit ' .. root .. '/d.txt')
  child.type_keys('x')
  H.eq(
    vim.wait(10000, function()
      return child.lua_get([[require('perforated.ui.float').active ~= nil]])
    end, 20),
    true
  )
  child.type_keys('n')
  wait([[vim.bo.filetype == 'perforated-description']])
  child.type_keys('Line one', '<CR>', 'Line two', '<C-s>')
  wait(
    [[(require('perforated.buffer').get(vim.fn.bufnr(']]
      .. root
      .. [[/d.txt')) or {}).status == 'opened']]
  )
  local out = server:p4(
    { '-ztag', 'changes', '-s', 'pending', '-l' },
    { client = 'alice_ws', cwd = root }
  ).stdout
  H.expect.no_equality(out:find('Line one\nLine two', 1, true), nil)
end

return T
