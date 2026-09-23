-- M3: describe, history, annotate, blame line, lookup, Swarm links (real p4d).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

-- History of a.txt:
--   CL 1  add   a1 / a2 / a3 (+ b.txt)
--   CL 2  edit  line 2 → B2          (bob)
--   CL 3  edit  line 3 → C3
--   CL 4  pending: b.txt opened and shelved; a.txt opened in the default CL, line 1 → local
local function setup()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files(
    'alice_ws',
    root,
    { ['a.txt'] = 'a1\na2\na3\n', ['b.txt'] = 'b1\n' },
    'initial import\nwith detail'
  )
  local bob = server.dir .. '/bob'
  server:client('bob_ws', bob, 'bob')
  server:p4({ 'sync' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4({ 'edit', bob .. '/a.txt' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  H.write(bob .. '/a.txt', 'a1\nB2\na3\n')
  server:p4({ 'submit', '-d', 'bob fixes line 2' }, { client = 'bob_ws', user = 'bob', cwd = bob })
  server:p4({ 'sync' }, { client = 'alice_ws', cwd = root })
  server:p4({ 'edit', root .. '/a.txt' }, { client = 'alice_ws', cwd = root })
  H.write(root .. '/a.txt', 'a1\nB2\nC3\n')
  server:p4({ 'submit', '-d', 'alice changes line 3' }, { client = 'alice_ws', cwd = root })
  server:p4({ 'change', '-i' }, {
    client = 'alice_ws',
    cwd = root,
    stdin = 'Change: new\nDescription:\n\tshelf work\n',
  })
  server:p4({ 'edit', '-c', '4', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  H.write(root .. '/b.txt', 'b2\n')
  server:p4({ 'shelve', '-c', '4' }, { client = 'alice_ws', cwd = root })
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      checkout = { prompt = false },
    },
  })
  child.o.lines, child.o.columns = 40, 160
  child.cmd('edit ' .. root .. '/a.txt')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000)
end

local function wait(expr, ms)
  vim.uv.sleep(50)
  if child.is_blocked() then
    error('child blocked: ' .. vim.inspect(vim.rpcrequest(child.job.channel, 'nvim_get_mode')))
  end
  H.eq(H.wait(child, expr, ms or 15000), true)
end

local function text()
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

local function wait_text(s)
  wait(
    ([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find(%q, 1, true) ~= nil]]):format(
      s
    )
  )
end

local function goto_line(s)
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(s, 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error('line not found: ' .. s .. '\n' .. text())
end

local WIN_NAMES =
  [[(function() local t = vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0)); table.sort(t); return t end)()]]

--- p4 commands run since the log was cleared, as "cmd arg…" strings (global options dropped).
local function p4_calls(pattern)
  return child.lua_get(([[(function()
    local out = {}
    for _, e in ipairs(require('perforated.core.log').entries()) do
      local s = table.concat(e.argv, ' ')
      if s:find(%q) then out[#out + 1] = s end
    end
    return out
  end)()]]):format(pattern))
end

T['m3'] = MiniTest.new_set({
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

T['m3']['describe a submitted CL: header, description, inline diff, d'] = function()
  child.cmd('P4 describe 3')
  wait_text('CL 3')
  wait_text('//depot/a.txt')
  local t = text()
  H.neq(t:find('submitted', 1, true), nil)
  H.neq(t:find('alice@alice_ws', 1, true), nil)
  H.neq(t:find('alice changes line 3', 1, true), nil)
  goto_line('//depot/a.txt')
  child.type_keys('<Tab>')
  wait_text('+C3')
  t = text()
  H.neq(t:find('-a3', 1, true), nil)
  H.neq(t:find('@@', 1, true), nil)
  child.type_keys('d')
  wait([[#vim.api.nvim_tabpage_list_wins(0) == 2]])
  H.eq(child.lua_get(WIN_NAMES), { 'perforated:////depot/a.txt#2', 'perforated:////depot/a.txt#3' })
end

T['m3']['describe a pending CL: workspace diff and shelved files (vs base, vs head)'] = function()
  child.cmd('P4 describe 4')
  wait_text('Shelved (1)')
  local t = text()
  H.neq(t:find('shelf work', 1, true), nil)
  H.neq(t:find('Files (1)', 1, true), nil)
  goto_line('Files (1)')
  child.type_keys('j', '<Tab>') -- the opened b.txt: base vs workspace file
  wait_text('+b2')
  local row = goto_line('Shelved (1)') + 1
  child.api.nvim_win_set_cursor(0, { row, 0 })
  child.type_keys('d')
  wait([[#vim.api.nvim_tabpage_list_wins(0) == 2]])
  H.eq(
    child.lua_get(WIN_NAMES),
    { 'perforated:////depot/b.txt#1', 'perforated:////depot/b.txt@=4' }
  )
  child.cmd('tabclose')
  wait([[vim.bo.filetype == 'perforated']])
  child.api.nvim_win_set_cursor(0, { row, 0 })
  child.type_keys('gh')
  wait([[#vim.api.nvim_tabpage_list_wins(0) == 2]])
  H.eq(
    child.lua_get(WIN_NAMES),
    { 'perforated:////depot/b.txt#head', 'perforated:////depot/b.txt@=4' }
  )
end

T['m3']['describe Q: files to quickfix (workspace paths when mapped)'] = function()
  child.cmd('P4 describe 1')
  wait_text('//depot/b.txt')
  child.type_keys('Q')
  wait([[#vim.fn.getqflist() == 2]])
  local names = child.lua_get(
    [[vim.tbl_map(function(e) return vim.fn.bufname(e.bufnr) end, vim.fn.getqflist())]]
  )
  table.sort(names)
  H.eq(names, { root .. '/a.txt', root .. '/b.txt' })
end

T['m3']['history: float, d diffs vs previous, gd describes, paging, Q loclist'] = function()
  child.lua([[require('perforated.config').set({ history = { limit = 2 } })]])
  child.cmd('P4 filelog')
  wait_text('#3')
  local t = text()
  H.neq(t:find('#2', 1, true), nil)
  H.eq(t:find('#1 ', 1, true), nil) -- page 1 = 2 revisions
  H.eq(child.api.nvim_win_get_cursor(0)[1], 1)
  H.neq(t:find('more (gn)', 1, true), nil)
  child.type_keys('gn')
  wait_text('initial import')
  goto_line('#2')
  child.type_keys('d')
  wait([[#vim.api.nvim_tabpage_list_wins(0) == 2]])
  H.eq(child.lua_get(WIN_NAMES), { 'perforated:////depot/a.txt#1', 'perforated:////depot/a.txt#2' })
  child.cmd('tabclose')
  child.type_keys('q') -- the history float stays open in its tab
  child.cmd('P4 filelog')
  wait_text('#3')
  goto_line('#2')
  child.type_keys('gd')
  wait_text('bob fixes line 2')
  H.neq(text():find('bob@bob_ws', 1, true), nil)
  child.cmd('tabclose')
  child.type_keys('q') -- the history float stays open in its tab
  child.cmd('P4 filelog')
  wait_text('#3')
  child.type_keys('Q')
  wait([[#vim.fn.getloclist(0) == 2]])
  H.eq(
    child.lua_get([[vim.fn.bufname(vim.fn.getloclist(0)[1].bufnr)]]),
    'perforated:////depot/a.txt#3'
  )
end

T['m3']['history presenter = quickfix'] = function()
  child.lua([[require('perforated.config').set({ history = { presenter = 'quickfix' } })]])
  child.cmd('P4 filelog')
  wait([[#vim.fn.getloclist(0) == 3]])
end

T['m3']['annotate: two p4 calls, CL per line, ~ walks back, <BS> returns, Q'] = function()
  child.lua([[require('perforated.core.log').clear()]])
  child.cmd('P4 annotate')
  wait([[vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find('^1 ') ~= nil]])
  local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
  H.eq(lines[1]:match('^(%d+)%s+(%S+)'), '1')
  H.eq({ lines[2]:match('^(%d+)%s+(%S+)') }, { '2', 'bob' })
  H.eq({ lines[3]:match('^(%d+)%s+(%S+)') }, { '3', 'alice' })
  H.eq(#p4_calls('annotate'), 1)
  H.eq(#p4_calls('filelog'), 1)
  H.eq(#child.lua_get([[require('perforated.core.log').entries()]]), 2)
  H.eq(child.wo.scrollbind, true)
  -- ~ on line 3 (CL 3 = #3): the file at #2, where line 3 came from CL 1.
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.type_keys('~')
  wait([[vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]:find('^1 ') ~= nil]])
  H.eq(
    child.lua_get(
      [[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr('l'))))]]
    ),
    'perforated:////depot/a.txt#2'
  )
  child.type_keys('<BS>')
  wait([[vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]:find('^3 ') ~= nil]])
  H.eq(
    child.lua_get(
      [[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr('l'))))]]
    ),
    root .. '/a.txt'
  )
  -- Q on line 2: lines from CL 2 in the source window's location list.
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys('Q')
  wait([[#vim.fn.getloclist(vim.fn.win_getid(vim.fn.winnr('l'))) == 1]])
  child.lua([[vim.api.nvim_set_current_win(require('perforated.views.annotate')._last.win)]])
  child.type_keys('<CR>') -- describe
  wait_text('bob fixes line 2')
end

T['m3']['annotate: local edits show "Not submitted"; q closes'] = function()
  child.lua([[vim.bo.readonly = false; vim.bo.modifiable = true]])
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'mine' })
  wait([[#(require('perforated.buffer').get().hunks or {}) > 0]])
  child.cmd('P4 annotate')
  wait(
    [[vim.api.nvim_buf_get_lines(0, 0, -1, false)[2] ~= nil and vim.api.nvim_buf_get_lines(0, 0, -1, false)[2]:find('^2 ') ~= nil]]
  )
  H.eq(child.api.nvim_buf_get_lines(0, 0, 1, false)[1], 'Not submitted')
  child.type_keys('q')
  H.eq(#child.api.nvim_tabpage_list_wins(0), 1)
  H.eq(child.wo.scrollbind, false)
end

T['m3']['blame line: virtual text after the debounce, one annotate for many moves'] = function()
  child.lua([[require('perforated.core.log').clear()]])
  child.cmd('P4 blame on')
  for _ = 1, 5 do
    child.type_keys('j', 'k')
  end
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys('<Ignore>') -- CursorMoved
  wait(
    [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.blame'], 0, -1, {}) > 0]]
  )
  local vt = child.lua_get(
    [=[vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.blame'], 0, -1, { details = true })[1][4].virt_text[1][1]]=]
  )
  H.neq(vt:find('bob', 1, true), nil)
  H.neq(vt:find('bob fixes line 2', 1, true), nil)
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.type_keys('<Ignore>')
  H.eq(H.wait(child, 'false', 500), false)
  H.eq(#p4_calls('annotate'), 1)
  child.cmd('P4 blame off')
  H.eq(
    child.lua_get(
      [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.blame'], 0, -1, {})]]
    ),
    0
  )
end

T['m3']['lookup: number → describe, user → changes; Swarm URL from config'] = function()
  child.lua([[require('perforated.config').set({ swarm = { url = 'https://swarm.example/' } })]])
  child.cmd('P4 lookup 2')
  wait_text('bob fixes line 2')
  child.type_keys('gX')
  wait([[vim.fn.getreg('"') == 'https://swarm.example/changes/2']])
  child.cmd('P4 lookup bob')
  wait_text('bob fixes line 2')
  H.eq(text():find('alice changes', 1, true), nil)
end

T['m3']['client view: L history, gd describe on a CL'] = function()
  child.cmd('P4')
  wait_text('CL 4')
  goto_line('CL 4')
  child.type_keys('gd')
  wait_text('Shelved (1)')
  child.cmd('tabclose')
  wait([[vim.bo.filetype == 'perforated']])
  goto_line('b.txt')
  child.type_keys('L')
  wait_text('initial import')
end

return T
