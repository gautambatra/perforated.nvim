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
  local function opened()
    H.eq(
      vim.wait(5000, function()
        return child.bo.filetype == 'TelescopePrompt'
      end, 30),
      true
    )
    vim.uv.sleep(100)
  end
  -- Opens in normal mode (picker_mode = 'normal'): i to type a filter.
  start_pick('telescope')
  opened()
  H.eq(child.api.nvim_get_mode().mode, 'n')
  child.type_keys('i', 'bra')
  vim.uv.sleep(300)
  child.type_keys('<CR>')
  wait_choice('bravo')
  start_pick('telescope')
  opened()
  child.type_keys('<Esc>') -- in normal mode, <Esc> closes
  wait_choice(vim.NIL)
  -- picker_mode = 'insert': straight into the prompt.
  child.lua([[require('perforated.config').set({ picker_mode = 'insert' })]])
  start_pick('telescope')
  opened()
  H.eq(child.api.nvim_get_mode().mode, 'i')
  child.type_keys('<C-c>') -- (<Esc> only leaves insert mode in telescope's prompt)
  wait_choice(vim.NIL)
end

T['picker']['auto prefers an installed picker, else the plugin list (vim.ui.select with notify)'] = function()
  local backend = [[(function()
    require('perforated.config').set({ picker = 'auto' })
    return require('perforated.picker').backend()
  end)()]]
  H.eq(child.lua_get(backend), 'mini') -- mini.nvim is on the test rtp; telescope isn't
  -- no picker plugin at all
  child.lua([[package.loaded['mini.pick'] = nil
    vim.opt.runtimepath:remove(vim.g.perforated_test_root .. '/.deps/mini.nvim')]])
  H.eq(child.lua_get(backend), 'perforated')
  child.lua([[require('perforated.config').set({ toast = { backend = 'notify' } })]])
  H.eq(child.lua_get(backend), 'select')
end

--- The plugin's own list (`picker = 'perforated'`).
local LIST = [[require('perforated.picker.list')._active]]

local function start_list(opts)
  child.lua(([[require('perforated.config').set({ picker = 'perforated' })
    _G.choice, _G.calls = 'pending', 0
    local items = {}
    for _, n in ipairs({ 'alpha', 'bravo', 'charlie', 'delta' }) do items[#items + 1] = { name = n } end
    require('perforated.picker').pick({
      title = 'Test',
      items = items,
      multi = %s,
      format = function(it) return it.name end,
      preview = function(it) return { 'about ' .. it.name } end,
      on_choice = function(chosen)
        _G.calls = _G.calls + 1
        _G.choice = chosen and table.concat(vim.tbl_map(function(c) return c.name end, chosen), ',') or vim.NIL
      end,
    })]]):format(tostring(opts and opts.multi or false)))
end

local function list_row()
  return child.lua_get(('vim.api.nvim_win_get_cursor(%s.list_win)[1]'):format(LIST))
end

T['picker']['perforated list: j/k wrap, preview follows, <CR> chooses, q cancels once'] = function()
  start_list()
  H.eq(child.lua_get(LIST .. ' ~= nil'), true)
  H.eq(list_row(), 1)
  child.type_keys('k') -- wraps to the last
  H.eq(list_row(), 4)
  child.type_keys('j') -- and back to the first
  H.eq(list_row(), 1)
  child.type_keys('<Down>', '<Down>')
  H.eq(list_row(), 3)
  local preview = child.lua_get(
    ([[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%s.prev_win), 0, -1, false)]]):format(
      LIST
    )
  )
  H.eq(preview, { 'about charlie' })
  child.type_keys('<CR>')
  wait_choice('charlie')
  H.eq(child.lua_get(LIST), vim.NIL) -- closed
  start_list()
  child.type_keys('q')
  wait_choice(vim.NIL)
  H.eq(child.lua_get('_G.calls'), 1)
end

T['picker']['perforated list: typing filters (fuzzy); <CR> right after typing uses it'] = function()
  start_list()
  local function shown()
    return child.lua_get(([[vim.api.nvim_buf_get_lines(%s.list_buf, 0, -1, false)]]):format(LIST))
  end
  child.type_keys('i', 'cre') -- fuzzy: c…r…e in that order matches only charlie
  vim.uv.sleep(100) -- past the debounce
  H.eq(shown(), { '  charlie' })
  child.type_keys('<BS>', '<BS>', '<BS>', 'zz')
  vim.uv.sleep(100)
  H.eq(shown(), { '  no matches' })
  child.type_keys('<BS>', '<BS>', 'elt')
  vim.uv.sleep(100)
  H.eq(shown(), { '  delta' })
  child.type_keys('<CR>')
  wait_choice('delta')
  -- Enter in the same burst as the typing (before TextChangedI / the debounce)
  start_list()
  child.type_keys('i')
  child.api.nvim_input('brav<CR>')
  wait_choice('bravo')
  -- arrows move the list from the filter line; <Esc> goes back to the list
  start_list()
  child.type_keys('i', 'a')
  vim.uv.sleep(100)
  child.type_keys('<Down>')
  local second = vim.trim(shown()[2])
  child.type_keys('<Esc>')
  H.eq(child.lua_get(('vim.api.nvim_get_current_win() == %s.list_win'):format(LIST)), true)
  H.eq(list_row(), 2)
  child.type_keys('<CR>')
  wait_choice(second)
end

T['picker']['perforated list: opened from insert mode, it starts in normal mode'] = function()
  -- The checkout prompt opens the changelist chooser on the first keystroke in a read-only file.
  child.lua([[_G.start_list = function()
    require('perforated.config').set({ picker = 'perforated' })
    _G.choice = 'pending'
    require('perforated.picker').pick({ title = 'T', items = { 'alpha', 'bravo', 'charlie' },
      format = function(s) return s end,
      on_choice = function(c) _G.choice = c and c[1] or vim.NIL end })
  end
  vim.keymap.set('i', '<F2>', '<Cmd>lua _G.start_list()<CR>')]])
  child.type_keys('i', '<F2>')
  vim.uv.sleep(50)
  H.eq(child.api.nvim_get_mode().mode, 'n')
  child.type_keys('j')
  H.eq(list_row(), 2)
  H.eq(child.lua_get('vim.v.errmsg'), '')
  child.type_keys('<CR>')
  wait_choice('bravo')
end

T['picker']['perforated list: the selected row is highlighted, also while typing a filter'] = function()
  start_list()
  local function sel_row()
    return child.lua_get(([[(function()
      local ns = vim.api.nvim_get_namespaces()['perforated.picker.list.sel']
      local m = vim.api.nvim_buf_get_extmarks(%s.list_buf, ns, 0, -1, { details = true })
      return #m == 1 and m[1][4].line_hl_group == 'PerforatedMenuSel' and m[1][2] + 1 or #m
    end)()]]):format(LIST))
  end
  H.eq(sel_row(), 1)
  child.type_keys('j', 'j')
  H.eq(sel_row(), 3)
  -- Not 'cursorline': configs often turn it off in windows that aren't current.
  child.type_keys('i', 'a') -- the filter line has the cursor now
  vim.uv.sleep(100)
  H.eq(sel_row(), 1)
  child.type_keys('<Down>')
  H.eq(sel_row(), 2)
  child.type_keys('<C-c>')
  wait_choice(vim.NIL)
end

T['picker']['a picker plugin that fails falls back to the plugin list, not vim.ui.select'] = function()
  child.lua([[require('perforated.config').set({ picker = 'telescope' })]]) -- not installed
  child.lua([[vim.ui.select = function() _G.used_select = true end]])
  child.lua([[require('perforated.picker').pick({ title = 'T', items = { 'x' },
    format = function(s) return s end, on_choice = function() end })]])
  H.eq(child.lua_get(LIST .. ' ~= nil'), true)
  H.eq(child.lua_get('_G.used_select'), vim.NIL)
end

T['picker']['perforated list: m marks several (multi); leaving the picker cancels'] = function()
  start_list({ multi = true })
  child.type_keys('m', 'j', 'm') -- alpha, then charlie (m also moves down)
  child.type_keys('<CR>')
  wait_choice('alpha,charlie')
  start_list()
  child.cmd('wincmd p') -- another window
  wait_choice(vim.NIL)
  H.eq(child.lua_get(LIST), vim.NIL)
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
  H.eq(
    H.wait(
      child,
      [[vim.api.nvim_buf_get_name(0):find('^perforated://files/') and #vim.api.nvim_tabpage_list_wins(0) == 3]]
    ),
    true
  )
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  H.eq(vim.tbl_contains(names, 'perforated:////depot/b.txt#1'), true)
  H.eq(vim.tbl_contains(names, 'perforated:////depot/b.txt#2'), true)
end

T['changes']["a user's submitted CL expands into its files; d diffs one against its previous revision"] = function()
  child.cmd('P4 changes -u bob')
  local function goto_text(t)
    H.eq(
      H.wait(
        child,
        ([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find(%q, 1, true) ~= nil]]):format(
          t
        )
      ),
      true
    )
    for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find(t, 1, true) then
        child.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end
  goto_text('bob work')
  H.eq(buf_text():find('//depot/b.txt', 1, true), nil) -- collapsed
  child.type_keys('l')
  goto_text('//depot/b.txt')
  H.neq(child.api.nvim_get_current_line():find('edit', 1, true), nil)
  H.neq(child.api.nvim_get_current_line():find('#2', 1, true), nil)
  child.type_keys('d')
  H.eq(H.wait(child, [[#vim.api.nvim_list_tabpages() == 3]]), true)
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  table.sort(names)
  H.eq(names, { 'perforated:////depot/b.txt#1', 'perforated:////depot/b.txt#2' })
  child.cmd('tabclose')
  -- gD: diff against a picked revision; the older one goes left.
  child.lua([[vim.ui.select = function(items, _, cb)
      for _, r in ipairs(items) do if tostring(r.rev) == '1' then return cb(r) end end
    end
    require('perforated.config').set({ picker = 'select' })]])
  goto_text('//depot/b.txt')
  child.type_keys('gD')
  vim.uv.sleep(200)
  H.eq(H.wait(child, [[#vim.api.nvim_list_tabpages() == 3]]), true)
  local wins = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  H.eq({ wins[1], wins[#wins] }, { 'perforated:////depot/b.txt#1', 'perforated:////depot/b.txt#2' })
  child.cmd('tabclose')
  -- Same keys as the client view: i edits a description, <F5> refreshes (gr and C are gone).
  local function map(lhs)
    return child.lua_get(('vim.fn.maparg(%q, "n", false, true).desc or ""'):format(lhs))
  end
  H.eq(map('i'), 'perforated: Edit description')
  H.eq(map('<F5>'), 'perforated: Refresh')
  H.eq(map('gr'):find('perforated', 1, true), nil)
  H.eq(map('C'):find('perforated', 1, true), nil)
  -- h on the file collapses its changelist; the files stay loaded for the next l.
  goto_text('//depot/b.txt')
  child.type_keys('h')
  H.eq(
    H.wait(
      child,
      [[not table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('//depot/b.txt', 1, true)]]
    ),
    true
  )
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
  H.write(root .. '/b.txt', 'b changed\n')
  child.lua([[vim.ui.select = function(items, opts, cb)
    _G.labels = vim.tbl_map(opts.format_item, items)
    cb(items[1])
  end]])
  child.cmd('P4 pick pending')
  H.eq(
    H.wait(
      child,
      [[vim.api.nvim_buf_get_name(0):find('^perforated://files/') and #vim.api.nvim_tabpage_list_wins(0) == 3]]
    ),
    true
  )
  H.eq(child.lua_get('_G.labels')[1], 'default  (1 files)')
end

T['changes']['changelist pickers preview the K popup: description, files, shelf'] = function()
  -- CL 7: pending, b.txt opened in it and shelved.
  local out = server:p4(
    { 'change', '-i' },
    { client = 'alice_ws', cwd = root, stdin = 'Change: new\nDescription:\n\tparser fix\n' }
  ).stdout
  local cl = out:match('Change (%d+) created')
  server:p4({ 'edit', '-c', cl, root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  server:p4({ 'shelve', '-c', cl }, { client = 'alice_ws', cwd = root })
  child.lua([[require('perforated.config').set({ picker = 'perforated' })]])
  child.cmd('P4 pick pending')
  H.eq(H.wait(child, LIST .. ' ~= nil'), true)
  local text = ([[table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%s.prev_win), 0, -1, false), '\n')]]):format(
    LIST
  )
  -- The default changelist first (nothing opened in it), then CL 7.
  H.eq(H.wait(child, text .. [[:find('default changelist · pending', 1, true) ~= nil]]), true)
  child.type_keys('j')
  H.eq(H.wait(child, text .. [[:find('Shelved (1)', 1, true) ~= nil]]), true)
  local preview = child.lua_get(text)
  H.neq(preview:find(('CL %s · pending · alice@alice_ws'):format(cl), 1, true), nil)
  H.neq(preview:find('  parser fix', 1, true), nil)
  H.neq(preview:find('Files (1)', 1, true), nil)
  H.neq(preview:find('//depot/b.txt#1', 1, true), nil)
  -- … in the popup's colours.
  local groups = child.lua_get(
    ([[vim.tbl_map(function(m) return m[4].line_hl_group end,
    vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(%s.prev_win), -1, 0, -1, { details = true }))]]):format(
      LIST
    )
  )
  H.eq(vim.tbl_contains(groups, 'PerforatedTitle'), true)
  H.eq(vim.tbl_contains(groups, 'PerforatedShelved'), true)
  child.type_keys('q')
  -- Submitted changelists too.
  child.cmd('P4 pick submitted')
  H.eq(H.wait(child, LIST .. ' ~= nil'), true)
  H.eq(H.wait(child, text .. [[:find('· submitted ·', 1, true) ~= nil]]), true)
  H.neq(child.lua_get(text):find('Files (1)', 1, true), nil)
  child.type_keys('q')
end

T['changes']['quickfix window: x reverts and M moves the entry'] = function()
  server:p4({ 'edit', root .. '/a.txt', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  server:p4(
    { 'change', '-i' },
    { client = 'alice_ws', cwd = root, stdin = 'Change: new\nDescription:\n\ttarget\n' }
  )
  child.cmd('P4 opened')
  H.eq(H.wait(child, [[#vim.fn.getqflist() == 3]]), true)
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.change ~= 'default' and it.change ~= 'new' then return cb(it) end end
  end]])
  -- entry 2 = a.txt, entry 3 = b.txt (entry 1 is the default CL header)
  child.cmd('copen')
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.type_keys('gm')
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys('x')
  H.eq(H.wait(child, 'false', 2000), false)
  local out = server:p4({ '-ztag', 'opened' }, { client = 'alice_ws', cwd = root }).stdout
  H.eq(out:find('//depot/a.txt', 1, true), nil)
  H.expect.no_equality(out:find('change 7', 1, true), nil)
end

return T
