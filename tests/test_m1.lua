-- M1 daily-driver flows against a real p4d: check-out prompt, sticky CL, add on write, revert,
-- diff, hunks, quickfix lists, statusline, stale detection and toasts.
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root, bob_root

local FILES = {
  ['a.txt'] = 'one\ntwo\nthree\nfour\nfive\n',
  ['b.txt'] = 'bee\n',
  ['src/c.txt'] = 'see\n',
}

local function setup(config)
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, FILES, 'initial')
  server:p4config(root, 'alice_ws')
  bob_root = server.dir .. '/bob'
  server:client('bob_ws', bob_root, 'bob')
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob_root })
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_deep_extend('force', {
      p4 = P.p4,
      checkout = { prompt_grace = 0 },
      startup_check = true,
      poll = { interval = 0 },
    }, config or {}),
  })
end

local function edit(rel)
  child.cmd('edit ' .. root .. '/' .. rel)
end

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
end

local function status()
  return child.lua_get([[(require('perforated.buffer').get() or {}).status]])
end

--- Wait until the child sits in the modal prompt (getchar).
local function wait_prompt()
  local ok = vim.wait(10000, function()
    return child.lua_get([[require('perforated.ui.float').active ~= nil]])
  end, 20)
  H.eq(ok, true)
end

local function opened()
  local out = server:p4({ '-ztag', 'opened' }, { client = 'alice_ws', cwd = root }).stdout
  local files = {}
  for depot, change in out:gmatch('%.%.%. depotFile (%S+).-%.%.%. change (%S+)') do
    files[depot] = change
  end
  return files
end

T['checkout'] = MiniTest.new_set({
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

T['checkout']['unopened file is clean and read-only; statusline shows #have'] = function()
  edit('a.txt')
  wait(
    [[require('perforated.buffer').get() and require('perforated.buffer').get().status == 'clean']]
  )
  H.eq(child.bo.readonly, true)
  H.eq(child.lua_get('vim.b.perforated_status'), '#1')
end

T['checkout']['first change prompts; <CR> checks out to default; signs appear'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/a.txt'], 'default')
  H.eq(child.bo.readonly, false)
  H.eq(child.api.nvim_get_current_line(), 'ne')
  wait([[#require('perforated.buffer').get().hunks == 1]])
  local marks = child.lua_get(
    [[vim.api.nvim_buf_get_extmarks(0, require('perforated.signs').ns, 0, -1, { details = true })]]
  )
  H.eq(#marks, 1)
  H.eq(marks[1][4].sign_hl_group, 'PerforatedChange')
  wait([[vim.b.perforated_status == 'edit@default ~1']])
end

T['checkout']['n creates a changelist which becomes sticky for the next file'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('n')
  H.eq(H.wait(child, [[vim.bo.filetype == 'perforated-description']]), true)
  child.type_keys('Fix the parser', '<C-s>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  local cl = opened()['//depot/a.txt']
  H.neq(cl, 'default')
  H.eq(child.lua_get([[require('perforated').workspace().sticky_cl]]), cl)

  edit('b.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/b.txt'], cl)
end

T['checkout']['s skips: buffer stays modified, read-only, not opened'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('s')
  H.eq(child.lua_get([[require('perforated.ui.float').active]]), vim.NIL)
  H.eq(child.bo.readonly, true)
  H.eq(child.bo.modified, true)
  H.eq(opened()['//depot/a.txt'], nil)
end

T['checkout']['c offers "+ new changelist…" at the end of the list'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.lua([[
    vim.ui.select = function(items, opts, cb)
      _G.labels = vim.tbl_map(opts.format_item, items)
      cb(items[#items])
    end
  ]])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('c')
  wait([[vim.bo.filetype == 'perforated-description']])
  child.type_keys('Created from the picker', '<C-s>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  local labels = child.lua_get('_G.labels')
  H.eq(labels[1], 'default')
  H.eq(labels[#labels], '+ new changelist…')
  local cl = opened()['//depot/a.txt']
  H.neq(cl, 'default')
  H.eq(child.lua_get([[require('perforated').workspace().sticky_cl]]), cl)
end

T['checkout']['cancelling the picker is "not now": :e! and a new edit prompt again'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.lua([[vim.ui.select = function(_, _, cb) cb(nil) end]])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('c')
  -- The picker opens after an async `p4 changes`; wait for the cancellation to land.
  wait([[vim.bo.readonly == true]])
  H.eq(opened()['//depot/a.txt'], nil)
  child.cmd('edit!')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/a.txt'], 'default')
end

T['checkout']['<Esc> dismisses without skipping the buffer'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<Esc>')
  H.eq(child.bo.readonly, true)
  H.eq(child.lua_get([[require('perforated.checkout')._state(0).skip]]), vim.NIL)
end

T['checkout']['keys typed during the grace period are replayed as text'] = function()
  child.stop()
  setup({ checkout = { prompt_grace = 400 } })
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('I', 'X')
  wait_prompt()
  child.type_keys('YZ') -- within the grace period: text, not choices
  vim.uv.sleep(500)
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.type_keys('<Esc>')
  H.eq(child.api.nvim_get_current_line(), 'XYZone')
end

T['checkout']['write right after choosing waits for the in-flight edit'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<CR>')
  child.cmd('write')
  H.eq(child.bo.modified, false)
  H.eq(table.concat(vim.fn.readfile(root .. '/a.txt'), '\n'):sub(1, 3), 'ne\n')
  H.eq(opened()['//depot/a.txt'], 'default')
end

T['checkout']['p4 edit flipping the mode bit does not trigger a file-changed prompt'] = function()
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.cmd('checktime')
  H.eq(child.api.nvim_get_mode().blocking, false)
  H.eq(child.cmd_capture('messages'):find('W16', 1, true), nil)
end

T['checkout']['new file: add prompt on write'] = function()
  edit('new.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'new']])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'fresh' })
  child.cmd('write')
  wait_prompt()
  child.type_keys('<CR>')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  H.eq(opened()['//depot/new.txt'], 'default')
  wait(
    [[vim.b.perforated_status == ' add@default +1' or vim.b.perforated_status:find('add@default')]]
  )
end

T['ops'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      setup()
      server:p4({ 'edit', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
      H.write(root .. '/a.txt', 'one\nTWO\nthree\nfour\nfive\nsix\n')
      edit('a.txt')
      wait([[#((require('perforated.buffer').get() or {}).hunks or {}) == 2]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['ops']['hunk navigation, preview and reset'] = function()
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua([[require('perforated.signs').nav(true)]])
  H.eq(child.api.nvim_win_get_cursor(0)[1], 2)
  child.lua([[require('perforated.signs').nav(true)]])
  H.eq(child.api.nvim_win_get_cursor(0)[1], 6)
  child.lua([[require('perforated.signs').nav(true)]]) -- wraps
  H.eq(child.api.nvim_win_get_cursor(0)[1], 2)
  local win = child.lua([[return require('perforated.signs').preview()]])
  H.eq(
    child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, false),
    { '-two', '+TWO' }
  )
  child.lua([[require('perforated.signs').reset()]])
  H.eq(child.api.nvim_buf_get_lines(0, 1, 2, false), { 'two' })
  wait([[#require('perforated.buffer').get().hunks == 1]])
  child.cmd('undo')
  wait([[#require('perforated.buffer').get().hunks == 2]])
end

T['ops'][':P4 diff opens a tab with the depot revision in diff mode; q closes it'] = function()
  child.cmd('P4 diff')
  wait('#vim.api.nvim_list_tabpages() == 2')
  local wins = child.api.nvim_tabpage_list_wins(0)
  H.eq(#wins, 2)
  local left = child.api.nvim_win_get_buf(wins[1])
  H.eq(child.api.nvim_buf_get_name(left), 'perforated:////depot/a.txt#1')
  wait(('vim.b[%d].perforated_loaded == true'):format(left))
  H.eq(child.api.nvim_buf_get_lines(left, 0, -1, false), { 'one', 'two', 'three', 'four', 'five' })
  H.eq(child.api.nvim_get_option_value('diff', { win = wins[1] }), true)
  H.eq(child.api.nvim_get_option_value('diff', { win = wins[2] }), true)
  child.api.nvim_set_current_win(wins[1])
  child.type_keys('q')
  H.eq(#child.api.nvim_list_tabpages(), 1)
  H.eq(child.wo.diff, false)
end

T['ops'][':P4 diff fires User PerforatedDiffOpen / PerforatedDiffClose (once)'] = function()
  child.lua([[
    _G.events = {}
    for _, name in ipairs({ 'PerforatedDiffOpen', 'PerforatedDiffClose' }) do
      vim.api.nvim_create_autocmd('User', {
        pattern = name,
        callback = function(ev) table.insert(_G.events, { name = name, data = ev.data }) end,
      })
    end
  ]])
  local file_buf = child.api.nvim_get_current_buf()
  child.cmd('P4 diff')
  wait('#_G.events == 1')
  local ev = child.lua_get('_G.events')
  H.eq(#ev, 1)
  H.eq(ev[1].name, 'PerforatedDiffOpen')
  local d = ev[1].data
  H.eq(d.tab, child.api.nvim_get_current_tabpage())
  H.eq(d.bufs.right, file_buf)
  H.eq(child.api.nvim_buf_get_name(d.bufs.left), 'perforated:////depot/a.txt#1')
  H.eq(d.spec, '//depot/a.txt#1')
  H.eq(child.api.nvim_win_get_buf(d.wins.left), d.bufs.left)
  -- Closing via :tabclose (not q) must still fire the close event exactly once.
  child.cmd('tabclose')
  H.eq(H.wait(child, '#_G.events == 2'), true)
  vim.uv.sleep(200)
  ev = child.lua_get('_G.events')
  H.eq(#ev, 2)
  H.eq(ev[2].name, 'PerforatedDiffClose')
  H.eq(ev[2].data.bufs.right, file_buf)
  H.eq(child.wo.diff, false)
end

T['ops'][':P4 diff survives a user OptionSet autocmd that throws'] = function()
  child.lua([[
    vim.api.nvim_create_autocmd('OptionSet', {
      pattern = 'diff',
      callback = function() vim.cmd('synthax off') end,
    })
  ]])
  child.cmd('P4 diff')
  wait('#vim.api.nvim_list_tabpages() == 2')
  local wins = child.api.nvim_tabpage_list_wins(0)
  H.eq(child.api.nvim_get_option_value('diff', { win = wins[1] }), true)
  H.eq(child.api.nvim_get_option_value('diff', { win = wins[2] }), true)
  H.expect.no_equality(child.cmd_capture('messages'):find('E492', 1, true), nil)
end

T['ops']['lualine component renders the statusline'] = function()
  child.lua([[
    -- Minimal stand-in for lualine's component base class.
    package.preload['lualine.component'] = function()
      local C = {}
      C.__index = C
      function C:extend()
        local cls = setmetatable({}, { __index = self })
        cls.__index = cls
        return cls
      end
      return C
    end
  ]])
  local text = child.lua_get([[require('lualine.components.perforated'):update_status()]])
  H.eq(text, child.lua_get([[require('perforated').statusline()]]))
  H.expect.no_equality(text:find('edit@default', 1, true), nil)
end

T['ops'][':P4 revert! restores depot content and state'] = function()
  child.cmd('P4 revert!')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'two', 'three', 'four', 'five' })
  H.eq(opened()['//depot/a.txt'], nil)
end

T['ops'][':P4 opened and :P4 hunks fill the quickfix list'] = function()
  child.cmd('P4 opened')
  wait([[#vim.fn.getqflist() == 2]])
  local items = child.fn.getqflist()
  H.eq(items[1].valid, 0) -- default changelist header
  H.eq(child.fn.bufname(items[2].bufnr), root .. '/a.txt')
  H.eq(child.fn.getqflist({ context = 1 }).context.kind, 'opened')

  child.cmd('P4 hunks')
  wait([[vim.fn.getqflist({ title = 1 }).title:find('hunks') ~= nil and #vim.fn.getqflist() == 2]])
  local lnums = vim.tbl_map(function(i)
    return i.lnum
  end, child.fn.getqflist())
  H.eq(lnums, { 2, 6 })

  child.cmd('wincmd p')
  child.cmd('P4 hunks %')
  H.eq(#child.fn.getloclist(0), 2)
end

T['ops']['perforated:// URIs load depot revisions'] = function()
  child.cmd('edit ' .. vim.fn.fnameescape('perforated:////depot/b.txt#1'))
  wait('vim.b.perforated_loaded == true')
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'bee' })
  H.eq(child.bo.modifiable, false)
end

T['ops']['large files are diffed off the main thread'] = function()
  child.lua([[
    require('perforated.config').set({ signs = { max_lines = 3 } })
    local engine = require('perforated.diff.engine')
    local orig = engine.hunks_async
    _G.async_calls = 0
    engine.hunks_async = function(...) _G.async_calls = _G.async_calls + 1; return orig(...) end
  ]])
  child.api.nvim_buf_set_lines(0, 2, 3, false, { 'THREE' })
  wait(
    [[#require('perforated.buffer').get().hunks == 2 and require('perforated.buffer').get().hunks[1].b_count == 2]]
  )
  H.eq(child.lua_get('_G.async_calls') >= 1, true)
end

T['modes'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['modes']['on_write: no prompt, checked out when written'] = function()
  setup({ checkout = { prompt = false, on_write = true } })
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  H.eq(child.lua_get([[require('perforated.ui.float').active]]), vim.NIL)
  H.eq(opened()['//depot/a.txt'], nil)
  child.cmd('write')
  H.eq(opened()['//depot/a.txt'], 'default')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
end

T['modes']['checkout.dirs limits automatic behaviour'] = function()
  setup()
  child.lua(
    ([[require('perforated.config').set({ checkout = { dirs = { %q } } })]]):format(root .. '/src')
  )
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  vim.uv.sleep(300)
  H.eq(child.lua_get([[require('perforated.ui.float').active]]), vim.NIL)
  edit('src/c.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.type_keys('x')
  wait_prompt()
  child.type_keys('s')
end

T['modes']["external diff runs p4 diff with the user's own P4DIFF"] = function()
  server = P.new()
  local tool_log = server.dir .. '/tool.log'
  local tool = server.dir .. '/mydiff'
  H.write(tool, '#!/bin/sh\necho "$@" > ' .. tool_log .. '\n')
  vim.uv.fs_chmod(tool, tonumber('755', 8))
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, FILES, 'initial')
  server:p4config(root, 'alice_ws')
  server:p4({ 'edit', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
  child = H.child({
    env = { P4CONFIG = '.p4config', P4DIFF = tool },
    config = { p4 = P.p4, poll = { interval = 0 }, diff = { external_terminal = false } },
  })
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  -- unchanged: no diff (tool not launched), just a message
  child.lua(
    [[_G.msgs = {}; local n = vim.notify; vim.notify = function(m, ...) table.insert(_G.msgs, m); n(m, ...) end]]
  )
  child.cmd('P4 diff!')
  wait(
    [[vim.tbl_contains(vim.tbl_map(function(m) return m:match('identical') ~= nil end, _G.msgs), true)]]
  )
  H.eq(vim.uv.fs_stat(tool_log), nil)
  H.eq(#child.api.nvim_list_tabpages(), 1)
  child.lua(
    [[vim.bo.readonly = false; vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'changed' }); vim.cmd('write')]]
  )
  child.cmd('P4 diff!')
  H.eq(
    vim.wait(10000, function()
      return vim.uv.fs_stat(tool_log) ~= nil
    end, 50),
    true
  )
  local args = vim.fn.readfile(tool_log)[1]
  -- `$P4DIFF <depot copy> <workspace file>` — even though the file is unchanged.
  local old, new = args:match('^(%S+) (%S+)$')
  H.eq(new, root .. '/a.txt')
  H.eq(vim.fs.basename(old), 'a.txt_1')
end

T['modes']['revert -a reverts only unchanged files'] = function()
  setup()
  server:p4({ 'edit', root .. '/a.txt', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  H.write(root .. '/b.txt', 'changed\n')
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.cmd('P4 revert -a ' .. root .. '/a.txt ' .. root .. '/b.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.eq(opened(), { ['//depot/b.txt'] = 'default' })
end

T['modes']['keymap preset is buffer-local to Perforce buffers'] = function()
  setup({ keymaps = 'default' })
  edit('a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.eq(child.fn.maparg(']h', 'n', false, true).buffer, 1)
  H.eq(child.fn.maparg('<leader>pd', 'n', false, true).rhs, '<Plug>(perforated-diff)')
  local other = H.tmp() .. '/x.txt'
  H.write(other, 'x')
  child.cmd('edit ' .. other)
  H.eq(child.fn.maparg(']h', 'n'), '')
end

T['stale'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      setup({ toast = { timeout = 300 } })
      server:p4({ 'edit', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
      edit('a.txt')
      -- Activation check done and probe baseline established.
      wait([[require('perforated').workspace().last_max ~= nil]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local function bob_submits()
  server:p4({ 'edit', bob_root .. '/a.txt' }, { client = 'bob_ws', user = 'bob', cwd = bob_root })
  H.write(bob_root .. '/a.txt', 'bob was here\n')
  server:p4({ 'submit', '-d', 'bob change' }, { client = 'bob_ws', user = 'bob', cwd = bob_root })
end

T['stale']['a submit elsewhere raises one toast and statusline markers'] = function()
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
  bob_submits()
  child.lua([[require('perforated.poll').probe(require('perforated').workspace())]])
  wait([[#require('perforated.ui.toast').visible() == 1]])
  local t = child.lua_get([[require('perforated.ui.toast').visible()[1].title]])
  H.eq(t, 'Perforce: 1 opened file(s) now stale')
  local line = child.lua_get([[require('perforated.ui.toast').visible()[1].lines[1] ]])
  H.expect.no_equality(line:find('#1→#2 · CL 2 · bob', 1, true), nil)
  wait([[vim.g.perforated_status.stale == 1]])
  wait([[require('perforated').statusline():find('↓#1→#2', 1, true) ~= nil]])
  H.expect.no_equality(
    child.lua_get([[require('perforated').statusline()]]):find('↓1', 1, true),
    nil
  )

  -- Same head revision: no second toast.
  child.lua([[require('perforated.ui.toast').dismiss()]])
  child.lua([[require('perforated.poll').refresh(require('perforated').workspace())]])
  vim.uv.sleep(500)
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
end

T['stale']['toast countdown starts only with user activity; unfocused toasts wait'] = function()
  child.lua([[require('perforated.ui.toast').show('t', { 'x' })]])
  vim.uv.sleep(600)
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 1)
  child.type_keys('l')
  wait([[#require('perforated.ui.toast').visible() == 0]], 3000)

  child.cmd('doautocmd FocusLost')
  child.lua([[require('perforated.ui.toast').show('later', { 'y' })]])
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
  child.cmd('doautocmd FocusGained')
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 1)
  H.eq(#child.lua_get([[require('perforated.ui.toast').history()]]), 2)
end

return T
