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

T['client view']['W switches to another of your clients in the same window'] = function()
  local root2 = server.dir .. '/ws2'
  server:client('alice_other', root2)
  server:p4({ 'sync' }, { client = 'alice_other', cwd = root2 })
  server:p4({ 'change', '-i' }, {
    client = 'alice_other',
    cwd = root2,
    stdin = 'Change: new\nClient: alice_other\nDescription:\n\tOther work\n',
  })
  open_view()
  local win = child.api.nvim_get_current_win()
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.client == 'alice_other' then return cb(it) end end
  end]])
  child.type_keys('W')
  wait([[(function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find('Other work', 1, true) then return true end
    end
  end)()]])
  H.eq(child.api.nvim_get_current_win(), win)
  H.eq(has_line('Client alice_other'), true)
  H.eq(has_line('Fix parser'), false)
  -- The file buffers keep their own workspace.
  H.eq(
    child.lua_get(
      [[require('perforated').workspace(vim.fn.bufnr(...)):client()]],
      { root .. '/d.txt' }
    ),
    'alice_ws'
  )
  -- And back.
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.client == 'alice_ws' then return cb(it) end end
  end]])
  child.type_keys('W')
  wait([[(function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find('Fix parser', 1, true) then return true end
    end
  end)()]])
  H.eq(has_line('Client alice_ws'), true)
end

T['client view']['W keeps the client and shows p4 message when the switch fails'] = function()
  local spec = server:p4({ 'client', '-o', 'alice_far' }).stdout
  spec = spec:gsub('\nRoot:[^\n]*', '\nRoot:\t' .. server.dir .. '/far')
  spec = spec:gsub('\nHost:[^\n]*', '\nHost:\telsewhere')
  if not spec:find('\nHost:') then
    spec = spec .. '\nHost:\telsewhere\n'
  end
  server:p4({ 'client', '-i' }, { stdin = spec })
  open_view()
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.client == 'alice_far' then return cb(it) end end
  end]])
  child.type_keys('W')
  H.eq(H.wait_message(child, 'can only be used from host', 15000), true)
  H.eq(H.wait_message(child, 'Perforce: error'), true)
  H.eq(has_line('Client alice_ws'), true)
  H.eq(has_line('Fix parser'), true)
end

T['client view']['Recent submitted lists my submits from outside this client view'] = function()
  -- alice_ws no longer maps //depot/elsewhere/...; alice submits there from another client.
  local spec = server:p4({ 'client', '-o', 'alice_ws' }).stdout
  spec = spec .. '\t-//depot/elsewhere/... //alice_ws/elsewhere/...\n'
  server:p4({ 'client', '-i' }, { stdin = spec })
  local root2 = server.dir .. '/ws2'
  server:client('alice_other', root2)
  server:submit_files('alice_other', root2, { ['elsewhere/x.txt'] = 'x\n' }, 'Outside my view')
  open_view()
  H.eq(has_line('Outside my view'), true)
end

T['client view']['a non-zero opened-file count uses PerforatedCount'] = function()
  open_view()
  local row = goto_line('Fix parser')
  -- Highlights are drawn by a decoration provider: read the tree's per-row spans.
  local groups = child.lua_get(([[(function()
    local v = require('perforated.views.client')._get(vim.b.perforated_ws)
    local hls, line = v.tree.row_hls[%d], vim.api.nvim_buf_get_lines(0, %d, %d + 1, false)[1]
    local out = {}
    for i = 1, #hls, 3 do
      out[line:sub(hls[i] + 1, hls[i + 1])] = hls[i + 2]
    end
    return out
  end)()]]):format(row - 1, row - 1, row - 1))
  H.eq(groups['  (1)'], 'PerforatedCount')
end

T['client view']['the path of a stale file uses PerforatedStale; others keep their colour'] = function()
  open_view()
  local function groups(text)
    local row = goto_line(text)
    return child.lua_get(([[(function()
      local v = require('perforated.views.client')._get(vim.b.perforated_ws)
      local hls, line = v.tree.row_hls[%d], vim.api.nvim_buf_get_lines(0, %d, %d + 1, false)[1]
      local out = {}
      for i = 1, #hls, 3 do
        out[line:sub(hls[i] + 1, hls[i + 1])] = hls[i + 2]
      end
      return out
    end)()]]):format(row - 1, row - 1, row - 1))
  end
  wait([[(]] .. view_expr(root) .. [[).data.modified ~= nil]])
  H.eq(groups('c.txt')['c.txt'], 'PerforatedStale') -- stale (bob submitted c.txt)
  H.neq(groups('b.txt')['b.txt'], 'PerforatedStale')
end

--- Text → highlight group of the client view row containing `text`.
local function row_groups(text)
  local row = goto_line(text)
  return child.lua_get(([[(function()
    local v = require('perforated.views.client')._get(vim.b.perforated_ws)
    local hls, line = v.tree.row_hls[%d], vim.api.nvim_buf_get_lines(0, %d, %d + 1, false)[1]
    local out = {}
    for i = 1, #hls, 3 do
      out[line:sub(hls[i] + 1, hls[i + 1])] = hls[i + 2]
    end
    return out
  end)()]]):format(row - 1, row - 1, row - 1))
end

T['client view']['changelist numbers use PerforatedChangelist; unresolved is orange'] = function()
  open_view()
  H.eq(row_groups('CL 2  Fix parser')['CL 2'], 'PerforatedChangelist')
  H.eq(row_groups('initial import  alice')['1'], 'PerforatedChangelist') -- Sync CL
  H.eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = 'PerforatedUnresolved' }).fg]]), 0xff8700)
  -- a colorscheme or user definition wins
  child.cmd('highlight PerforatedUnresolved guifg=#123456')
  child.lua([[require('perforated.hl').setup()]])
  H.eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = 'PerforatedUnresolved' }).fg]]), 0x123456)
end

T['client view']['stale / unresolved files: their ● and path take the badge colour'] = function()
  H.write(root .. '/c.txt', 'c-local\n') -- changed, so c.txt gets a ●
  open_view()
  wait([[(]] .. view_expr(root) .. [[).data.modified ~= nil]])
  local g = row_groups('c.txt')
  H.eq(g['c.txt'], 'PerforatedStale')
  H.eq(g['● '], 'PerforatedStale')
  -- syncing the opened file schedules a resolve: unresolved outranks stale
  server:p4({ 'sync', root .. '/c.txt' }, { client = 'alice_ws', cwd = root })
  child.type_keys('gr')
  wait(
    ([[vim.iter((%s).data.opened or {}):any(function(f) return f.unresolved ~= nil end)]]):format(
      view_expr(root)
    )
  )
  wait([[(]] .. view_expr(root) .. [[).data.modified ~= nil]])
  goto_line('Pending')
  g = row_groups('c.txt')
  H.eq(g['c.txt'], 'PerforatedUnresolved')
  H.eq(g['● '], 'PerforatedUnresolved')
  H.eq(row_groups('a.txt')['● '], 'PerforatedModified') -- neither: unchanged colour
end

T['client view']['Pending: default first, then the newest changelists'] = function()
  server:p4({ 'change', '-i' }, {
    client = 'alice_ws',
    cwd = root,
    stdin = 'Change: new\nDescription:\n\tNewer work\n',
  })
  open_view()
  local default, newer, older =
    goto_line('default'), goto_line('Newer work'), goto_line('Fix parser')
  H.eq(default < newer and newer < older, true)
end

T['client view']['a slow Sync CL query does not hold back the other sections'] = function()
  -- Wrap p4 so the Sync CL query (`changes -m1 #have`) takes 3 s.
  local wrapper = server.dir .. '/slow-p4'
  H.write(wrapper, ('#!/bin/sh\ncase "$*" in *#have*) sleep 3;; esac\nexec %s "$@"\n'):format(P.p4))
  vim.uv.fs_chmod(wrapper, tonumber('755', 8))
  child.lua(
    'vim.g.perforated = vim.tbl_extend("force", vim.g.perforated, { p4 = ... })',
    { wrapper }
  )
  child.lua([[require('perforated.config').reload(); require('perforated.core.env').reset()]])
  child.cmd('P4')
  local t0 = vim.uv.hrtime()
  wait(
    [[vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] ~= nil and (function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find('Fix parser', 1, true) then return true end
    end
  end)()]],
    2500
  )
  H.eq((vim.uv.hrtime() - t0) / 1e6 < 2500, true)
  H.eq(has_line('Sync CL: loading…'), true)
  wait(('not (%s).loading'):format(view_expr(root)))
  H.eq(has_line('Sync CL: loading…'), false)
end

T['client view']['shows pending CLs, files, shelves, stale files, submitted, reconcile'] = function()
  open_view()
  H.eq(#child.api.nvim_list_tabpages(), 2)
  H.eq(has_line('Client alice_ws'), true)
  H.eq(has_line('Sync CL: 1  initial import'), true) -- the newest changelist we have
  H.eq(lines()[goto_line('Sync CL:')]:match('^(%s*)Sync CL:'), '    ') -- level with the changelists
  H.eq(goto_line('Sync CL:') < goto_line('Pending'), true)
  H.eq(vim.trim(lines()[goto_line('Pending') - 1]), '') -- a blank line between sections
  H.eq(vim.trim(lines()[goto_line('Recent submitted') - 1]), '')
  H.eq(has_line('Pending'), true)
  H.eq(has_line('default'), true)
  H.eq(has_line('CL 2  Fix parser'), true)
  H.eq(has_line('a.txt'), true)
  H.eq(has_line('Shelved (1)'), true)
  H.eq(has_line('stale'), true) -- c.txt
  H.eq(has_line('Needs attention'), true)
  -- the stale c.txt is in the default changelist: shown after the action
  H.neq(table.concat(lines(), '\n'):find('edit (default)', 1, true), nil)
  H.eq(has_line('Recent submitted'), true)
  H.eq(has_line('initial import'), true)
  H.eq(has_line('Workspace reconcile'), true)
  H.eq(goto_line('Workspace reconcile') < goto_line('Recent submitted'), true)
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

T['client view']['<F5> refreshes the view (like gr)'] = function()
  open_view()
  H.eq(has_line('b.txt'), true)
  -- Reverted outside the plugin: nothing tells the view, until <F5>.
  server:p4({ 'revert', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  vim.uv.sleep(300)
  H.eq(has_line('b.txt'), true)
  child.type_keys('<F5>')
  wait(
    ('not table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), "\\n"):find("b.txt", 1, true)'):format(
      view_expr(root)
    )
  )
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
  child.lua([[require('perforated.ui.prompt').confirm = function() return 1 end]])
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
  child.type_keys('m', 'gm')
  H.eq(H.wait(child, 'false', 1500), false)
  local o = opened()
  H.eq(o['//depot/b.txt'], '2')
  H.eq(o['//depot/c.txt'], '2')
end

T['client view']['gm on a changelist moves all its files; the picker offers the others'] = function()
  open_view()
  child.lua([[vim.ui.select = function(items, opts, cb)
    _G.offered = vim.tbl_map(function(it) return it.change end, items)
    _G.title = opts.prompt
    for _, it in ipairs(items) do if it.change == 'default' then return cb(it) end end
  end]])
  goto_line('CL 2  Fix parser')
  child.type_keys('gm')
  wait([[_G.offered ~= nil]])
  H.eq(child.lua_get('_G.offered'), { 'default', 'new' }) -- every other changelist, not CL 2
  H.eq(child.lua_get('_G.title'):find('Move 1 file(s) from CL 2', 1, true) ~= nil, true)
  H.eq(H.wait(child, 'false', 1500), false)
  H.eq(opened()['//depot/a.txt'], 'default')

  -- From the default changelist into a new one (created in the description float).
  child.lua([[vim.ui.select = function(items, _, cb)
    _G.offered = vim.tbl_map(function(it) return it.change end, items)
    for _, it in ipairs(items) do if it.change == 'new' then return cb(it) end end
  end]])
  wait([[(]] .. view_expr(root) .. [[).loading == false]])
  goto_line('default')
  child.type_keys('gm')
  wait([[vim.bo.filetype == 'perforated-description']])
  H.eq(child.lua_get('_G.offered'), { '2', 'new' })
  child.type_keys('Moved here', '<Esc>', '<C-s>')
  H.eq(H.wait(child, 'false', 2000), false)
  local o = opened()
  H.eq(o['//depot/a.txt'], o['//depot/b.txt'])
  H.eq(o['//depot/a.txt'], o['//depot/c.txt'])
  H.neq(o['//depot/a.txt'], 'default')
  H.neq(o['//depot/a.txt'], '2')
end

T['client view']['K popup: C edits the description in place, then comes back'] = function()
  open_view()
  goto_line('CL 2  Fix parser')
  child.type_keys('K')
  wait([[vim.bo.filetype == 'perforated-changelist']])
  local win = child.api.nvim_get_current_win()
  child.type_keys('C')
  wait([[vim.bo.filetype == 'perforated-description']])
  H.eq(child.api.nvim_get_current_win(), win) -- the same popup, now in edit mode
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'Fix parser', 'second line' })
  child.type_keys('ccFix the parser', '<Esc>', '<C-s>')
  wait([[vim.bo.filetype == 'perforated-changelist']])
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Fix the parser', 1, true) ~= nil]]
  )
  local spec = server:p4({ 'change', '-o', '2' }, { client = 'alice_ws', cwd = root }).stdout
  H.neq(spec:find('\tFix the parser\n\tsecond line', 1, true), nil)
  -- q in edit mode (unmodified) goes back to the popup too; q there closes it.
  child.type_keys('C')
  wait([[vim.bo.filetype == 'perforated-description']])
  child.type_keys('q')
  wait([[vim.bo.filetype == 'perforated-changelist']])
  child.type_keys('q')
  wait([[vim.bo.filetype == 'perforated']])
end

T['client view']['D shows "Opening diff view…" until the tab is open'] = function()
  H.write(root .. '/b.txt', 'b2\n')
  open_view()
  child.lua([[
    local toast = require('perforated.ui.toast')
    local busy = toast.busy
    _G.busy = {}
    toast.busy = function(msg)
      table.insert(_G.busy, msg)
      return busy(msg)
    end
  ]])
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  H.eq(child.lua_get('_G.busy'), { 'Opening diff view…' })
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
end

T['client view']['marks inside a collapsed changelist still apply'] = function()
  open_view()
  child.lua([[vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it.change == '2' then return cb(it) end end
  end]])
  goto_line('b.txt')
  child.type_keys('m', 'h') -- mark, then collapse the default CL (the cursor lands on it)
  H.eq(has_line('b.txt'), false)
  -- gm (a file action) runs on the hidden marked file, not on the changelist under the cursor.
  child.type_keys('gm')
  H.eq(H.wait(child, 'false', 1500), false)
  local o = opened()
  H.eq(o['//depot/b.txt'], '2')
  H.eq(o['//depot/c.txt'], 'default')
end

T['client view'][':P4 from another tab reuses the view; changes made there refresh it'] = function()
  open_view()
  child.cmd('tabprev')
  child.cmd('P4')
  H.eq(#child.api.nvim_list_tabpages(), 2)
  H.eq(child.api.nvim_get_current_buf(), child.lua_get(view_expr(root) .. '.buf'))
  child.cmd('tabprev')
  child.lua(
    ("require('perforated.checkout').revert(require('perforated').workspace(), { %q })"):format(
      root .. '/b.txt'
    )
  )
  wait(
    ('not table.concat(vim.api.nvim_buf_get_lines(%s.buf, 0, -1, false), "\\n"):find("b.txt", 1, true)'):format(
      view_expr(root)
    )
  )
end

T['client view']['the footer follows the view buffer, not its window'] = function()
  open_view()
  local floats = [[#vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ''
  end, vim.api.nvim_tabpage_list_wins(0))]]
  H.eq(child.lua_get(floats), 1)
  child.cmd('buffer ' .. root .. '/d.txt')
  H.eq(child.lua_get(floats), 0)
  child.cmd('doautocmd VimResized') -- used to fail: the footer outlived its buffer
  child.cmd('P4')
  wait(floats .. ' == 1')
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
  H.eq(H.wait_message(child, 'does not apply here'), true)
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

local FLOAT_LINES = [[(function()
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(w).relative == '' then return nil end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end)()]]

T['client view']['K shows the full description, opened and shelved files'] = function()
  open_view()
  goto_line('CL 2  Fix parser')
  child.type_keys('K')
  wait(FLOAT_LINES .. ' ~= nil')
  local text = table.concat(child.lua_get(FLOAT_LINES), '\n')
  H.expect.no_equality(text:find('second line', 1, true), nil) -- full description
  H.expect.no_equality(text:find('Files (1)', 1, true), nil)
  H.expect.no_equality(text:find('Shelved (1)', 1, true), nil)
  H.expect.no_equality(text:find('//depot/a.txt', 1, true), nil)
  child.type_keys('q')
  H.eq(child.lua_get(FLOAT_LINES), vim.NIL)
end

T['client view']['layout: 4 columns per level; the shelf lines up with the files'] = function()
  open_view()
  local function line_of(text)
    return lines()[goto_line(text)]
  end
  H.eq(line_of('Pending'):match('^▼ Pending') ~= nil, true)
  H.eq(line_of('CL 2  Fix parser'):match('^    ▼ CL 2') ~= nil, true)
  -- files at depth 2 start at column 8 (the ● marker column), and so does the shelf's triangle
  H.eq(line_of('a.txt  #1/#1'):match('^        ● edit') ~= nil, true)
  H.eq(line_of('b.txt'):match('^          edit') ~= nil, true) -- blank marker
  H.eq(line_of('Shelved (1)'):match('^        ▶ ') ~= nil, true)
  child.type_keys('l')
  H.eq(line_of('//depot/a.txt'):match('^            edit') ~= nil, true)
  H.eq(line_of('CL 1  20'):match('^    CL 1') ~= nil, true)
end

T['client view']['labels, fold triangles, shelved colour and CL-only yank'] = function()
  open_view()
  H.eq(has_line('▼ '), true)
  H.eq(has_line('▶ '), true) -- the collapsed shelf
  local ids = function()
    return child.lua_get(
      [[vim.tbl_map(function(a) return a.desc end,
      require('perforated.ui.keys').valid(]]
        .. view_expr(root)
        .. [[.actions, ]]
        .. view_expr(root)
        .. [[.tree:node_at()))]]
    )
  end
  goto_line('b.txt')
  H.eq(vim.tbl_contains(ids(), 'Diff against have revision'), true)
  H.eq(vim.tbl_contains(ids(), 'Get latest revision'), false) -- b.txt isn't stale
  H.eq(vim.tbl_contains(ids(), 'Revert if unchanged'), true)
  H.eq(vim.tbl_contains(ids(), 'Sync workspace'), true)
  H.eq(vim.tbl_contains(ids(), 'Copy CL number'), false)
  goto_line('Shelved (1)')
  child.type_keys('l')
  goto_line('//depot/a.txt')
  H.eq(vim.tbl_contains(ids(), 'Diff shelved vs base revision'), true)
  H.eq(vim.tbl_contains(ids(), 'Diff against have revision'), false)
  goto_line('CL 2  Fix parser')
  H.eq(vim.tbl_contains(ids(), 'Revert unchanged files'), true)
  H.eq(vim.tbl_contains(ids(), 'Get latest file revisions'), false) -- a.txt isn't stale
  goto_line('default')
  H.eq(vim.tbl_contains(ids(), 'Get latest file revisions'), true) -- c.txt is
  goto_line('CL 2  Fix parser')
  child.type_keys('y')
  H.eq(child.fn.getreg('"'), '2')
  H.eq(child.fn.maparg('.', 'n') ~= '', true)
  H.eq(child.fn.maparg('<Space>', 'n'), '')
end

--- Labels of the `.` menu for the line containing `text` ('-' for a separator).
local function menu_labels(text)
  goto_line(text)
  local v = view_expr(root)
  return child.lua_get(
    ([[vim.tbl_map(function(i) return i.separator and '-' or i.label end,
      require('perforated.ui.keys').menu_items(%s.actions, %s.tree:node_at(), %s.menu_layout))]]):format(
      v,
      v,
      v
    )
  )
end

--- Label → Ctrl hint of the `.` menu for the line containing `text`.
local function menu_hints(text)
  goto_line(text)
  local v = view_expr(root)
  return child.lua_get(([[(function()
    local out = {}
    for _, i in ipairs(require('perforated.ui.keys').menu_items(%s.actions, %s.tree:node_at(), %s.menu_layout)) do
      if i.label then out[i.label] = i.hint end
    end
    return out
  end)()]]):format(v, v, v))
end

T['client view']['changelist menu: fixed order, groups, only what applies'] = function()
  server:p4({ 'change', '-i' }, {
    client = 'alice_ws',
    cwd = root,
    stdin = 'Change: new\nDescription:\n\tEmpty one\n',
  })
  open_view()
  H.eq(menu_labels('CL 2  Fix parser'), {
    'Submit…',
    '-',
    'View changelist',
    'Diff all files',
    'Edit description',
    'Copy CL number',
    'Copy Swarm URL',
    'Send to quickfix',
    '-',
    'Revert unchanged files',
    'Revert files',
    'Move all files to another changelist',
    '-',
    'Shelve files',
    'Unshelve files',
    'Delete shelved files',
    '-',
    'Create new changelist',
    'Sync entire workspace',
    'Switch client',
  })
  -- default: stale c.txt → get latest; no CL number, description, shelf or Swarm
  H.eq(menu_labels('default'), {
    'Submit…',
    '-',
    'View changelist',
    'Diff all files',
    'Send to quickfix',
    'Get latest file revisions',
    '-',
    'Revert unchanged files',
    'Revert files',
    'Move all files to another changelist',
    '-',
    'Create new changelist',
    'Sync entire workspace',
    'Switch client',
  })
  -- describe stays on `gd`, in no menu of the view (submitted rows included)
  local sub = menu_labels('initial import')
  H.eq(vim.tbl_contains(sub, 'View changelist'), true) -- really a submitted row
  H.eq(vim.tbl_contains(sub, 'Describe changelist'), false)
  H.eq(child.lua_get([[vim.fn.maparg('gd', 'n', false, true).buffer]]), 1)
  -- an empty CL can be deleted; one with files can't
  local empty = menu_labels('Empty one')
  H.eq(vim.tbl_contains(empty, 'Delete changelist'), true)
  H.eq(vim.tbl_contains(empty, 'Submit…'), false)
  H.eq(empty[1], 'View changelist') -- no leading separator
  -- `.` draws the groups with rules, and the keys still choose
  goto_line('CL 2  Fix parser')
  child.type_keys('.')
  local menu = [[(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_win_get_config(w).relative ~= '' and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]:find('Submit') then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
  end)()]]
  wait(menu .. ' ~= nil')
  local shown = child.lua_get(menu)
  H.eq(shown[1]:match('^%s+P%s+Submit…%s+Ctrl%+S$') ~= nil, true)
  -- Ctrl shortcuts sit in one right-hand column, without parentheses
  local cols = {}
  for _, l in ipairs(shown) do
    local col = l:find('Ctrl+', 1, true)
    if col then
      cols[vim.fn.strdisplaywidth(l:sub(1, col - 1))] = true
    end
    H.eq(l:find('(Ctrl', 1, true), nil)
  end
  H.eq(vim.tbl_count(cols), 1)
  H.eq(#shown[2] > 0 and shown[2]:gsub('─', '') == '', true)
  child.type_keys('K')
  wait(FLOAT_LINES .. ' ~= nil')
  H.expect.no_equality(
    table.concat(child.lua_get(FLOAT_LINES), '\n'):find('second line', 1, true),
    nil
  )
end

T['client view']['file menu: fixed order, groups, only what applies'] = function()
  open_view()
  local tail = {
    '-',
    'Diff against have revision',
    'Diff against revision…',
    '-',
    'File history',
    'Annotate',
    'Time-lapse view',
    '-',
    'Create new changelist',
    'Sync entire workspace',
    'Switch client',
  }
  local function with_tail(head)
    return vim.list_extend(head, tail)
  end
  -- b.txt: default CL (no shelve), not stale (no get latest)
  H.eq(
    menu_labels('b.txt'),
    with_tail({
      'Open file',
      'Get revision…',
      '-',
      'Revert if unchanged',
      'Revert',
      'Move to another changelist',
    })
  )
  -- c.txt is stale; a.txt (CL 2) can be shelved
  H.eq(
    vim.list_slice(menu_labels('c.txt'), 1, 3),
    { 'Open file', 'Get latest revision', 'Get revision…' }
  )
  H.eq(vim.tbl_contains(menu_labels('a.txt'), 'Shelve'), true)
end

T['client view']['g@ syncs a file to a picked revision; gD diffs against one'] = function()
  open_view()
  child.lua([[
    require('perforated.picker').pick = function(spec)
      _G.picked = vim.tbl_map(spec.format, spec.items)
      _G.title = spec.title
      spec.on_choice({ spec.items[#spec.items] }) -- the oldest: #1
    end
    require('perforated.ui.prompt').confirm = function(msg) _G.asked = msg; return 1 end
  ]])
  goto_line('c.txt')
  child.type_keys('g@')
  wait('_G.asked ~= nil')
  H.eq(child.lua_get('_G.title'), 'Get revision of c.txt')
  local picked = child.lua_get('_G.picked')
  H.eq(#picked, 2)
  H.eq(picked[1]:match('^#2 ') ~= nil, true)
  H.eq(picked[2]:find('(have)', 1, true) ~= nil, true) -- c.txt has #1, head is #2
  H.eq(child.lua_get('_G.asked'):find('c.txt#1', 1, true) ~= nil, true)
  child.lua('_G.picked = nil')
  goto_line('a.txt')
  child.type_keys('gD')
  wait('_G.picked ~= nil')
  H.eq(child.lua_get('_G.title'), 'Diff a.txt against')
  wait([[vim.iter(vim.api.nvim_tabpage_list_wins(0)):any(function(w)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('a.txt#1', 1, true) ~= nil
  end)]])
end

T['client view']['action menu: a click chooses an item; a click outside cancels'] = function()
  child.o.mouse = 'a'
  open_view()
  -- Click the screen cell of the menu row containing `text` (or `row, col` when given).
  local function click(text, row, col)
    if text then
      row, col = unpack(child.lua_get(([[(function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local b = vim.api.nvim_win_get_buf(w)
          if vim.api.nvim_win_get_config(w).relative ~= '' then
            for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
              if l:find(%q, 1, true) then
                local p = vim.fn.screenpos(w, i, 3)
                return { p.row, p.col }
              end
            end
          end
        end
      end)()]]):format(text)))
    end
    child.api.nvim_input_mouse('left', 'press', '', 0, row - 1, col - 1)
    child.api.nvim_input_mouse('left', 'release', '', 0, row - 1, col - 1)
  end
  local menu_open = [[require('perforated.ui.float').active ~= nil]]
  goto_line('CL 2  Fix parser')
  child.type_keys('.')
  wait(menu_open)
  click('View changelist')
  wait(FLOAT_LINES .. ' ~= nil') -- the K popup
  H.expect.no_equality(
    table.concat(child.lua_get(FLOAT_LINES), '\n'):find('second line', 1, true),
    nil
  )
  child.type_keys('q')
  -- outside the menu: closes it, runs nothing
  goto_line('CL 2  Fix parser')
  child.type_keys('.')
  wait(menu_open)
  click(nil, child.o.lines - 2, child.o.columns - 2)
  wait('not (' .. menu_open .. ')')
  H.eq(child.lua_get(FLOAT_LINES), vim.NIL)
end

T['client view']['action menu: j/k, arrows or the pointer highlight an item; <CR> runs it'] = function()
  child.o.mouse = 'a'
  open_view()
  local sel = [[require('perforated.ui.float').selected]]
  goto_line('CL 2  Fix parser')
  child.type_keys('.')
  wait([[require('perforated.ui.float').active ~= nil]])
  H.eq(child.lua_get(sel), 'Submit…') -- no <CR> default: the first item
  H.eq(child.o.mousemoveevent, true) -- only while the menu is open
  child.type_keys('j') -- skips the separator
  H.eq(child.lua_get(sel), 'View changelist')
  child.type_keys('<Down>', '<Down>')
  H.eq(child.lua_get(sel), 'Edit description')
  child.type_keys('k')
  H.eq(child.lua_get(sel), 'Diff all files')
  child.type_keys('k', 'k', 'k', 'k') -- stops at the top
  H.eq(child.lua_get(sel), 'Submit…')
  -- the mouse pointer highlights what it is over
  local function screen_of(text)
    return child.lua_get(([[(function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then
          for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
            if l:find(%q, 1, true) then return vim.fn.screenpos(w, i, 4) end
          end
        end
      end
    end)()]]):format(text))
  end
  -- The pointer moves over 'View changelist'. A terminal reports movement only by updating the
  -- mouse position (getcharstr() never returns <MouseMove>), which the menu polls while open;
  -- headless Neovim has no pointer, so the test moves the position itself.
  local p = screen_of('View changelist')
  child.lua(([[
    local getmouse = vim.fn.getmousepos
    vim.fn.getmousepos = function() return { screenrow = %d, screencol = %d } end
    _G.restore = function() vim.fn.getmousepos = getmouse end
  ]]):format(p.row, p.col))
  wait(sel .. " == 'View changelist'") -- no key pressed
  child.lua('_G.restore()')
  child.type_keys('<CR>')
  wait(FLOAT_LINES .. ' ~= nil') -- the K popup
  H.expect.no_equality(
    table.concat(child.lua_get(FLOAT_LINES), '\n'):find('second line', 1, true),
    nil
  )
  H.eq(child.o.mousemoveevent, false) -- restored
  child.type_keys('q')
  -- a confirmation starts on its default, so <CR> alone still means the default
  child.lua([[vim.schedule(function()
    _G.r = require('perforated.ui.prompt').confirm('Sure?', '&Yes\n&No', 2)
  end)]])
  wait([[require('perforated.ui.float').active ~= nil]])
  H.eq(child.lua_get(sel), 'No  (<CR>)')
  child.type_keys('k', '<CR>')
  wait('_G.r == 1')
end

T['client view']['right-click opens the menu of the clicked line, not the cursor line'] = function()
  child.o.mouse = 'a'
  open_view()
  goto_line('Pending') -- the cursor stays here
  local row = goto_line('CL 2  Fix parser')
  goto_line('Pending')
  local pos = child.fn.screenpos(child.api.nvim_get_current_win(), row, 7)
  child.api.nvim_input_mouse('right', 'press', '', 0, pos.row - 1, pos.col - 1)
  wait([[require('perforated.ui.float').active ~= nil]])
  local menu = child.lua_get([[(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        local l = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
        if l[1] and l[1]:find('Submit', 1, true) then return l end
      end
    end
  end)()]])
  H.neq(menu, vim.NIL) -- the changelist's menu (starts with Submit…)
  H.eq(child.api.nvim_win_get_cursor(0)[1], row)
  -- right-clicking another line while the menu is open replaces it with that line's menu
  local brow
  for i, l in ipairs(lines()) do
    if l:find('b.txt', 1, true) then
      brow = i
      break
    end
  end
  local bpos = child.fn.screenpos(child.api.nvim_get_current_win(), brow, 12)
  child.api.nvim_input_mouse('right', 'press', '', 0, bpos.row - 1, bpos.col - 1)
  wait(
    ([[vim.api.nvim_win_get_cursor(0)[1] == %d and require('perforated.ui.float').active ~= nil]]):format(
      brow
    )
  )
  local first = child.lua_get([[(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        local l = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false)[1]
        if l and l:find('Open file', 1, true) then return l end
      end
    end
  end)()]])
  H.neq(first, vim.NIL) -- the file's menu (starts with Open file)
  child.type_keys('<Esc>')
end

T['client view']['a changelist resolves only with unresolved files; S, g<Del> act on its shelf'] = function()
  open_view()
  H.eq(vim.tbl_contains(menu_labels('CL 2  Fix parser'), 'Resolve'), false)
  child.lua(
    [[require('perforated.ops').unshelve = function(_, cl, files) _G.unsh = { cl, files } end
    require('perforated.ops').delete_shelved = function(_, cl, files) _G.del = { cl, files } end]]
  )
  goto_line('CL 2  Fix parser')
  child.type_keys('S')
  H.eq(child.lua_get('_G.unsh'), { '2' })
  child.type_keys('g', '<Del>')
  H.eq(child.lua_get('_G.del'), { '2' })
end

T['client view']['w diffs shelved vs workspace: one file, or the whole shelf in a tab'] = function()
  open_view()
  goto_line('Shelved (1)')
  child.type_keys('l')
  H.write(root .. '/a.txt', 'a3\n') -- differ from the shelved a2
  goto_line('//depot/a.txt')
  child.type_keys('w')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  table.sort(names)
  H.eq(names, { root .. '/a.txt', 'perforated:////depot/a.txt@=2' })
  child.cmd('tabclose')
  wait([[vim.bo.filetype == 'perforated']])
  goto_line('Shelved (1)')
  child.type_keys('w') -- the whole shelf: a diff tab (panel + pair)
  wait([[#vim.api.nvim_list_tabpages() == 3 and #vim.api.nvim_tabpage_list_wins(0) == 3]])
  wait(
    [[vim.tbl_contains(vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0)), 'perforated:////depot/a.txt@=2')]]
  )
  H.neq(
    table
      .concat(
        child.lua_get(
          [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
        ),
        ' '
      )
      :find(root .. '/a.txt', 1, true),
    nil
  )
end

T['client view']['changed files get ● (and unchanged ones are dimmed); saving updates it'] = function()
  open_view()
  local function row(text)
    for _, l in ipairs(lines()) do
      if l:find(text, 1, true) then
        return l
      end
    end
  end
  wait(([[(%s).data.modified ~= nil]]):format(view_expr(root)))
  H.neq(row('a.txt'):find('● edit', 1, true), nil) -- a.txt differs from its base
  H.eq(row('b.txt'):find('●', 1, true), nil) -- opened, unchanged
  -- edit and save b.txt: its marker appears without a full refresh
  child.cmd('tabfirst')
  child.cmd('edit ' .. root .. '/b.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'opened']])
  child.lua([[vim.bo.readonly = false]])
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'b changed' })
  child.cmd('write')
  child.cmd('tablast')
  wait(
    [[(function() for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do if l:find('b.txt', 1, true) then return l:find('●', 1, true) ~= nil end end end)()]]
  )
  -- describe buffer and :P4 opened carry the same information
  child.cmd('P4 describe 2')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('● edit', 1, true) ~= nil]]
  )
  child.cmd('P4 opened')
  wait([[#vim.fn.getqflist() >= 4]])
  local texts = child.lua_get(
    [[vim.tbl_map(function(e) return vim.api.nvim_buf_get_name(e.bufnr) .. '|' .. e.text end, vim.fn.getqflist())]]
  )
  local by = {}
  for _, t in ipairs(texts) do
    local name, text = t:match('^(.-)|(.*)$')
    by[vim.fs.basename(name)] = text
  end
  H.eq(by['a.txt']:sub(1, #'● '), '● ')
  H.eq(by['b.txt']:sub(1, #'● '), '● ')
  H.eq(by['c.txt']:sub(1, #'· '), '· ')
end

T['client view']['depot revisions load even when opened from inside an autocmd'] = function()
  child.lua(([[
    vim.api.nvim_create_autocmd('User', { pattern = 'NestTest', callback = function()
      _G.nested_buf = require('perforated.uri').buffer(require('perforated').workspace(vim.fn.bufnr(%q)), '//depot/b.txt#1')
    end })
    vim.api.nvim_exec_autocmds('User', { pattern = 'NestTest' })
  ]]):format(root .. '/d.txt'))
  wait([[vim.b[_G.nested_buf].perforated_loaded == true]])
  H.eq(child.lua_get([[vim.api.nvim_buf_get_lines(_G.nested_buf, 0, -1, false)]]), { 'b1' })
end

T['client view']['diff tab: moving the cursor in the panel loads each file (both sides)'] = function()
  open_view()
  goto_line('initial import')
  child.type_keys('D')
  -- The diff tab (floats count as windows: the client view's footer and the busy pop-up too).
  wait([[#vim.api.nvim_list_tabpages() == 3 and #vim.api.nvim_tabpage_list_wins(0) == 3]])
  -- Move through the panel the way a user does (CursorMoved inside the panel).
  local seen = {}
  for row = 3, 6 do
    child.lua(([[
      vim.api.nvim_win_set_cursor(0, { %d, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })
    ]]):format(row))
    local right = child.lua_get([[vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[3])]])
    wait(('vim.b[%d].perforated_loaded == true'):format(right))
    seen[#seen + 1] = child.api.nvim_buf_get_lines(right, 0, -1, false)[1]
  end
  table.sort(seen)
  H.eq(seen, { 'a1', 'b1', 'c1', 'd1' })
  -- The two diff windows share the width equally.
  local w =
    child.lua_get([[vim.tbl_map(vim.api.nvim_win_get_width, vim.api.nvim_tabpage_list_wins(0))]])
  H.eq(math.abs(w[2] - w[3]) <= 1, true)
end

T['client view']['views and diff tabs leave global window options alone'] = function()
  child.o.number, child.o.wrap, child.o.cursorline, child.o.signcolumn = true, true, false, 'auto'
  local function globals()
    return child.lua_get([[{ vim.go.number, vim.go.wrap, vim.go.cursorline, vim.go.signcolumn,
      vim.go.relativenumber, vim.go.foldcolumn }]])
  end
  local before = globals()
  open_view() -- client view: no numbers, cursorline, no wrap — in its own window only
  H.write(root .. '/b.txt', 'b2\n')
  goto_line('default')
  child.type_keys('D') -- diff tab with a file panel
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  child.cmd('tabnext 1')
  child.cmd('P4 annotate')
  -- (the annotate split binds and unwraps the source window)
  wait([[next(require('perforated.views.annotate')._views) ~= nil]])
  H.eq(globals(), before)
  child.cmd('tabnew')
  H.eq(child.wo.number, true) -- a new window still gets line numbers
  H.eq(child.wo.wrap, true)
end

--- Open the diff tab of the default changelist (b.txt changed); returns its window ids.
local function open_diff_tab()
  open_view()
  H.write(root .. '/b.txt', 'b2\n')
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  wait(
    [[#vim.tbl_filter(function(w) return vim.wo[w].diff end, vim.api.nvim_tabpage_list_wins(0)) == 2]]
  )
  return child.lua_get([[(function()
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative == '' then
        local kind = vim.wo[w].diff and 'side' or 'panel'
        out[kind] = out[kind] or {}
        table.insert(out[kind], w)
      end
    end
    return out
  end)()]])
end

local function win_ns(w)
  return child.lua_get(('vim.api.nvim_get_hl_ns({ winid = %d })'):format(w))
end

T['client view']['diff look: default is the colorscheme without syntax, diff windows only'] = function()
  local wins = open_diff_tab()
  local code = child.lua_get([[require('perforated.diff.look').ns_code]])
  H.eq(#wins.side, 2)
  for _, w in ipairs(wins.side) do
    H.eq(win_ns(w), code)
  end
  H.eq(win_ns(wins.panel[1]), -1) -- the panel keeps the colorscheme
  child.cmd('tabnext 1')
  H.eq(win_ns(child.api.nvim_get_current_win()), -1) -- other windows untouched
  -- kept: UI groups fall back to the colorscheme; syntax is blanked (verified on screen: plain text)
  H.eq(child.lua_get([[require('perforated.diff.look')._kept('DiffAdd')]]), true)
  H.eq(child.lua_get([[require('perforated.diff.look')._kept('String')]]), false)
  H.eq(
    child.lua_get(
      [[vim.api.nvim_get_hl(require('perforated.diff.look').ns_code, { name = 'Normal' })]]
    ),
    {}
  )
end

T['client view']['diff look: colors = perforated covers sides, panel and headers; survives :colorscheme'] = function()
  child.lua([[require('perforated.config').set({ diff = { colors = 'perforated' } })]])
  local wins = open_diff_tab()
  local look = [[require('perforated.diff.look')]]
  local code, ui = child.lua_get(look .. '.ns_code'), child.lua_get(look .. '.ns_ui')
  for _, w in ipairs(wins.side) do
    H.eq(win_ns(w), code)
  end
  H.eq(win_ns(wins.panel[1]), ui)
  local function hl(ns, name)
    return child.lua_get(('vim.api.nvim_get_hl(%d, { name = %q })'):format(ns, name))
  end
  H.eq(hl(code, 'Normal').bg, 0xfafafa)
  H.eq(hl(code, 'DiffAdd').bg, 0xe2fbe4)
  H.eq(hl(code, 'WinBar').bg, 0xf0f0f0) -- the headers
  -- crisp separators: a black line on the light background (not the colorscheme's dark one)
  H.eq(hl(code, 'WinSeparator'), { fg = 0x000000, bg = 0xfafafa })
  H.eq(hl(ui, 'WinSeparator'), { fg = 0x000000, bg = 0xfafafa })
  H.eq(hl(ui, 'Normal').bg, 0xfafafa)
  H.eq(hl(ui, 'Comment').fg, 0xa0a1a7) -- the panel keeps (palette) colours
  -- a colorscheme switch (your light/dark toggle) rebuilds; the diff stays light
  child.cmd('colorscheme default')
  H.eq(hl(code, 'Normal').bg, 0xfafafa)
  H.eq(win_ns(wins.side[1]), code)
end

T['client view']['diff look: a user OptionSet diff hook that resets namespaces cannot undo it'] = function()
  -- The snippet suggested for the author's config: reset on diffoff, apply only when unset.
  child.lua([[
    require('perforated.config').set({ diff = { colors = 'perforated' } })
    vim.api.nvim_create_autocmd('OptionSet', { pattern = 'diff', callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.wo[win].diff then
        if vim.api.nvim_get_hl_ns({ winid = win }) == -1 then
          require('perforated.diff.look').apply({ [win] = 'code' })
        end
      else
        vim.api.nvim_win_set_hl_ns(win, 0)
      end
    end })
  ]])
  local wins = open_diff_tab()
  local code = child.lua_get([[require('perforated.diff.look').ns_code]])
  for _, w in ipairs(wins.side) do
    H.eq(win_ns(w), code)
  end
end

T['client view']['diff look: colorscheme with syntax leaves diff windows alone; overrides'] = function()
  child.lua(
    [[require('perforated.config').set({ diff = { colors = 'colorscheme', syntax = true } })]]
  )
  local wins = open_diff_tab()
  for _, w in ipairs(vim.list_extend(wins.side, wins.panel)) do
    H.eq(win_ns(w), -1)
  end
  child.cmd('tabclose')
  child.lua(
    [[require('perforated.config').set({ diff = { colors = { diff_add = '#123456' }, syntax = false } })]]
  )
  child.cmd('tabnext 2')
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local code = child.lua_get([[require('perforated.diff.look').ns_code]])
  H.eq(child.lua_get(('vim.api.nvim_get_hl(%d, { name = "DiffAdd" }).bg'):format(code)), 0x123456)
  H.eq(child.lua_get(('vim.api.nvim_get_hl(%d, { name = "Normal" }).bg'):format(code)), 0xfafafa)
end

T['client view']['diff tab panel: the cursor stays on the files; j/k/arrows wrap around'] = function()
  open_view()
  H.write(root .. '/b.txt', 'b2\n')
  H.write(root .. '/c.txt', 'c-mine\n')
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local wins = child.api.nvim_tabpage_list_wins(0)
  local function row()
    return child.api.nvim_win_get_cursor(0)[1]
  end
  local function shown()
    return vim.fs.basename(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(wins[3])))
  end
  H.eq(row(), 3) -- rows 1-2: title and a blank line; files on 3 and 4
  H.eq(shown(), 'b.txt')
  child.type_keys('k') -- up from the first file wraps to the last
  H.eq({ row(), shown() }, { 4, 'c.txt' })
  child.type_keys('j') -- down from the last wraps to the first
  H.eq({ row(), shown() }, { 3, 'b.txt' })
  child.type_keys('<Up>')
  H.eq(row(), 4)
  child.type_keys('<Down>')
  H.eq(row(), 3)
  child.type_keys('2j') -- a count moves that many files
  H.eq(row(), 3)
  -- other motions can't leave the list
  child.type_keys('gg')
  H.eq(row(), 3)
  child.type_keys('G')
  wait('vim.api.nvim_win_get_cursor(0)[1] == 4')
  child.api.nvim_win_set_cursor(0, { 1, 0 }) -- e.g. a click on the title
  wait('vim.api.nvim_win_get_cursor(0)[1] == 3')
end

T['client view']['D opens the diff tab for a CL; <Tab> steps files'] = function()
  open_view()
  -- b.txt and c.txt are opened but unchanged: no diff tab, just a pop-up
  goto_line('default')
  child.type_keys('D')
  wait(
    [[vim.tbl_contains(vim.tbl_map(function(t) return (t.title .. ' ' .. table.concat(t.lines, ' ')):find('all 2 files are identical', 1, true) ~= nil end, require('perforated.ui.toast').history()), true)]]
  )
  H.eq(#child.lua_get([[require('perforated.ui.toast').visible()]]), 1)
  H.eq(#child.api.nvim_list_tabpages(), 2)
  -- one changed, one identical: only the changed one is diffed; the other is listed
  H.write(root .. '/b.txt', 'b2\n')
  goto_line('default')
  child.type_keys('D')
  wait([[#vim.api.nvim_list_tabpages() == 3]])
  local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  local ident = text:find('Identical (1):', 1, true)
  H.neq(ident, nil)
  H.eq(text:find('c.txt', 1, true) > ident, true)
  H.eq(text:find('b.txt', 1, true) < ident, true)
  child.type_keys('q')
  wait([[vim.bo.filetype == 'perforated']])
  -- both changed
  H.write(root .. '/c.txt', 'c-mine\n')
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
  -- The workspace file that left a diff window doesn't take its header along.
  child.cmd('tabnew | buffer ' .. child.fn.bufnr(first))
  H.eq(child.wo.winbar, '')
  child.cmd('tabclose')
  -- q from the workspace file (the right side) closes the whole tab too, as does :q there.
  for _, close in ipairs({ 'q', ':q<CR>' }) do
    goto_line('default')
    child.type_keys('D')
    wait([[#vim.api.nvim_list_tabpages() == 3]])
    wins = child.api.nvim_tabpage_list_wins(0)
    child.api.nvim_set_current_win(wins[3])
    H.neq(child.api.nvim_buf_get_name(0):find('^' .. vim.pesc(root)), nil)
    H.neq(child.wo.winbar:find('(workspace)', 1, true), nil)
    H.neq(child.api.nvim_get_option_value('winbar', { win = wins[2] }):find('(have)', 1, true), nil)
    child.type_keys(close)
    wait([[#vim.api.nvim_list_tabpages() == 2]])
    wait([[vim.bo.filetype == 'perforated']])
  end
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

T['client view']['multi-key actions (gY) can be chosen from the action menu'] = function()
  open_view()
  child.lua(
    [[require('perforated.ui.prompt').confirm = function(msg) _G.asked = msg; return 3 end]]
  )
  goto_line('b.txt')
  child.type_keys('.')
  vim.uv.sleep(300) -- the menu waits for keys (no RPC meanwhile)
  child.type_keys('g', 'Y')
  wait([[_G.asked == 'Sync the whole workspace?']])
end

T['client view']['Q sends a CL to quickfix; action menu lists only valid actions'] = function()
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
  for _, k in ipairs({ '<C-d>', '<C-r>', '<C-n>' }) do
    H.eq(child.lua_get(([[vim.fn.maparg('%s', 'n', false, true).buffer]]):format(k)), 1)
  end
  -- …and the action menu shows them beside the label
  local hints = menu_hints('CL 2  Fix parser')
  H.eq(hints['Revert files'], 'Ctrl+R')
  H.eq(hints['Create new changelist'], 'Ctrl+N')
  H.eq(hints['Diff all files'], 'Ctrl+D')
  H.eq(hints['View changelist'], nil)
  H.eq(
    child.lua_get(
      [[vim.tbl_map(require('perforated.ui.keys').ctrl_label, { '<C-S-t>', '<C-1>', '<F5>', 'gd' })]]
    ),
    { 'Ctrl+Shift+T', 'Ctrl+1' }
  )
  child.cmd('tabclose')
  child.lua([[require('perforated.config').set({ keys = { p4v = false } })]])
  child.cmd('bwipeout! ' .. child.lua_get(view_expr(root) .. '.buf'))
  open_view()
  H.eq(child.fn.maparg('<C-d>', 'n'), '')
  H.eq(menu_hints('CL 2  Fix parser')['Diff all files'], nil) -- no Ctrl+D
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
  H.eq(H.wait_message(child, 'default changelist has no description'), true)
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
