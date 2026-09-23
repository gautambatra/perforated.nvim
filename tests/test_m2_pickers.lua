-- M2: picker backends, :P4 pick, :P4 changes (paging, -u), quickfix-window actions.
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child

local ITEMS =
  [[{ { id = 1, name = 'alpha' }, { id = 2, name = 'bravo' }, { id = 3, name = 'charlie' } }]]

--- Start a picker asynchronously (some backends block) and record the choice in _G.choice.
local function start_pick(backend)
  child.lua(([[require('perforated.config').set({ picker = %q })]]):format(backend))
  child.lua_notify(([[
    _G.choice = 'pending'
    require('perforated.picker').pick({
      title = 'Test',
      items = %s,
      format = function(it) return it.name end,
      on_choice = function(items) _G.choice = items and items[1].name or vim.NIL end,
    })
  ]]):format(ITEMS))
end

local function wait_choice(expected)
  local ok = vim.wait(8000, function()
    return child.lua_get('_G.choice') ~= 'pending'
  end, 30)
  H.eq(ok, true)
  H.eq(child.lua_get('_G.choice'), expected)
end

T['picker'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = H.child()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['picker']['select backend'] = function()
  child.lua([[vim.ui.select = function(items, opts, cb) cb(items[2]) end]])
  start_pick('select')
  wait_choice('bravo')
end

T['picker']['mini.pick backend: choose and cancel'] = function()
  child.lua([[require('mini.pick').setup()]])
  start_pick('mini')
  vim.uv.sleep(300)
  child.type_keys('char', '<CR>')
  wait_choice('charlie')
  start_pick('mini')
  vim.uv.sleep(300)
  child.type_keys('<Esc>')
  wait_choice(vim.NIL)
end

T['picker']['telescope backend: choose and cancel'] = function()
  local tel = H.root .. '/.deps/telescope.nvim'
  if vim.fn.isdirectory(tel) == 0 then
    MiniTest.skip('telescope not in .deps (make deps)')
  end
  child.lua(
    ([[vim.opt.rtp:append(%q); vim.opt.rtp:append(%q); require('telescope').setup()]]):format(
      tel,
      H.root .. '/.deps/plenary.nvim'
    )
  )
  start_pick('telescope')
  H.eq(
    vim.wait(5000, function()
      return child.bo.filetype == 'TelescopePrompt'
    end, 30),
    true
  )
  child.type_keys('bra')
  vim.uv.sleep(300)
  child.type_keys('<CR>')
  wait_choice('bravo')
  start_pick('telescope')
  H.eq(
    vim.wait(5000, function()
      return child.bo.filetype == 'TelescopePrompt'
    end, 30),
    true
  )
  child.type_keys('<C-c>') -- (<Esc> only leaves insert mode in telescope's prompt)
  wait_choice(vim.NIL)
end

T['picker']['auto prefers an installed picker, falls back to vim.ui.select'] = function()
  child.lua([[package.preload['telescope'] = nil]])
  H.eq(
    child.lua_get([[(function()
    require('perforated.config').set({ picker = 'auto' })
    return require('perforated.picker').backend()
  end)()]]),
    'mini'
  ) -- mini.nvim is on the test rtp; telescope isn't
end

-- ---------------------------------------------------------------------------------------------

local server, root

local function setup_server()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, { ['a.txt'] = '0\n', ['b.txt'] = 'b\n' }, 'change 1')
  for i = 2, 5 do
    server:p4({ 'edit', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
    H.write(root .. '/a.txt', i .. '\n')
    server:p4({ 'submit', '-d', 'change ' .. i }, { client = 'alice_ws', cwd = root })
  end
  local bob = server.dir .. '/bob'
  server:client('bob_ws', bob, 'bob')
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4({ 'edit', bob .. '/b.txt' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  H.write(bob .. '/b.txt', 'bob\n')
  server:p4({ 'submit', '-d', 'bob work' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = { p4 = P.p4, poll = { interval = 0 }, startup_check = false },
  })
  child.cmd('edit ' .. root .. '/a.txt')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000)
end

local function buf_text()
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

T['changes'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      setup_server()
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['changes'][':P4 changes pages with gn and stops at the end'] = function()
  child.cmd('P4 changes -m 2')
  H.eq(
    H.wait(
      child,
      [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('CL 5', 1, true) ~= nil]]
    ),
    true
  )
  local t = buf_text()
  H.expect.no_equality(t:find('CL 6', 1, true), nil) -- newest (bob's)
  H.expect.no_equality(t:find('CL 5', 1, true), nil)
  H.eq(t:find('CL 4', 1, true), nil)
  child.type_keys('gn')
  H.eq(
    H.wait(
      child,
      [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('CL 3', 1, true) ~= nil]]
    ),
    true
  )
  child.type_keys('gn')
  H.eq(
    H.wait(
      child,
      [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('CL 1', 1, true) ~= nil]]
    ),
    true
  )
  vim.uv.sleep(300)
  child.type_keys('gn')
  vim.uv.sleep(300)
  H.eq(buf_text():find('more (gn)', 1, true), nil)
end

T['changes'][':P4 changes -u bob shows only bob; D opens the CL diff'] = function()
  child.cmd('P4 changes -u bob')
  H.eq(
    H.wait(
      child,
      [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('bob work', 1, true) ~= nil]]
    ),
    true
  )
  H.eq(buf_text():find('change 2', 1, true), nil)
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find('bob work', 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  child.type_keys('D')
  H.eq(H.wait(child, [[#vim.api.nvim_tabpage_list_wins(0) == 3]]), true)
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  H.eq(vim.tbl_contains(names, 'perforated:////depot/b.txt#1'), true)
  H.eq(vim.tbl_contains(names, 'perforated:////depot/b.txt#2'), true)
end

T['changes']["K on another user's submitted CL shows its description and files"] = function()
  child.cmd('P4 changes -u bob')
  H.eq(
    H.wait(
      child,
      [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('bob work', 1, true) ~= nil]]
    ),
    true
  )
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find('bob work', 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  child.type_keys('K')
  H.eq(H.wait(child, [[vim.api.nvim_win_get_config(0).relative ~= '']]), true)
  local text = buf_text()
  H.expect.no_equality(text:find('submitted', 1, true), nil)
  H.expect.no_equality(text:find('bob@bob_ws', 1, true), nil)
  H.expect.no_equality(text:find('//depot/b.txt#2', 1, true), nil)
end

T['changes'][':P4 pick pending opens the chosen CL in the diff tab'] = function()
  server:p4({ 'edit', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  child.lua([[vim.ui.select = function(items, opts, cb)
    _G.labels = vim.tbl_map(opts.format_item, items)
    cb(items[1])
  end]])
  child.cmd('P4 pick pending')
  H.eq(H.wait(child, [[#vim.api.nvim_tabpage_list_wins(0) == 3]]), true)
  H.eq(child.lua_get('_G.labels')[1], 'default  (1 files)')
end

T['changes']['quickfix window: x reverts and M moves the entry'] = function()
  server:p4({ 'edit', root .. '/a.txt', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  server:p4(
    { 'change', '-i' },
    { client = 'alice_ws', cwd = root, stdin = 'Change: new\nDescription:\n\ttarget\n' }
  )
  child.cmd('P4 opened')
  H.eq(H.wait(child, [[#vim.fn.getqflist() == 3]]), true)
  child.lua([[vim.fn.confirm = function() return 1 end]])
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.change ~= 'default' and it.change ~= 'new' then return cb(it) end end
  end]])
  -- entry 2 = a.txt, entry 3 = b.txt (entry 1 is the default CL header)
  child.cmd('copen')
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.type_keys('M')
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys('x')
  H.eq(H.wait(child, 'false', 2000), false)
  local out = server:p4({ '-ztag', 'opened' }, { client = 'alice_ws', cwd = root }).stdout
  H.eq(out:find('//depot/a.txt', 1, true), nil)
  H.expect.no_equality(out:find('change 7', 1, true), nil)
end

return T
