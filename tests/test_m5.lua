-- M5: time-lapse (real p4d).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
end

--- The time-lapse info panel's text.
local INFO =
  [[(function() local v = require('perforated.views.timelapse')._last; return v and v.ibuf and vim.api.nvim_buf_is_valid(v.ibuf) and table.concat(vim.api.nvim_buf_get_lines(v.ibuf, 0, -1, false), '\n') or '' end)()]]
local function info()
  return child.lua_get(INFO)
end

--- Deterministic pseudo-random edits: insert, delete or change lines.
local function revisions(count)
  local seed = 7
  local function rnd(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
  end
  local lines = {}
  for i = 1, 12 do
    lines[i] = 'line ' .. i
  end
  local out = { table.concat(lines, '\n') .. '\n' }
  for r = 2, count do
    for _ = 1, 1 + rnd(3) do
      local op = rnd(3)
      local at = 1 + rnd(#lines)
      if op == 0 or #lines < 4 then
        table.insert(lines, at, ('added r%d.%d'):format(r, rnd(1000)))
      elseif op == 1 then
        table.remove(lines, at)
      else
        lines[at] = ('changed r%d.%d'):format(r, rnd(1000))
      end
    end
    out[r] = table.concat(lines, '\n') .. '\n'
  end
  return out
end

local REVS = 30

local function setup()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  local contents = revisions(REVS)
  server:submit_files('alice_ws', root, { ['f.txt'] = contents[1] }, 'rev 1')
  for r = 2, REVS do
    server:p4({ 'edit', root .. '/f.txt' }, { client = 'alice_ws', cwd = root })
    H.write(root .. '/f.txt', contents[r])
    server:p4({ 'submit', '-d', 'rev ' .. r }, { client = 'alice_ws', cwd = root })
  end
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = { p4 = P.p4, poll = { interval = 0 }, startup_check = false },
  })
  child.o.lines, child.o.columns = 40, 160
  child.cmd('edit ' .. root .. '/f.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  return contents
end

T['timelapse'] = MiniTest.new_set({
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

T['timelapse']['every rebuilt revision equals p4 print; two p4 calls'] = function()
  local contents = setup()
  H.wait_idle(child) -- the buffer's own fstat / refresh must not count
  child.lua([[require('perforated.core.log').clear()]])
  child.lua(([[
    _G.tl = nil
    require('perforated.timelapse').load(require('perforated').workspace(), %q, function(tl, err)
      _G.tl, _G.err = tl or false, err
    end)
  ]]):format(root .. '/f.txt'))
  wait('_G.tl ~= nil')
  H.eq(child.lua_get('_G.err'), vim.NIL)
  H.eq(H.p4_subcommands(child), { 'filelog', 'annotate' })
  for r = 1, REVS do
    local got = child.lua_get(
      ('table.concat(require("perforated.timelapse").revision(_G.tl, %d), "\\n") .. "\\n"'):format(
        r
      )
    )
    H.eq(got, contents[r])
    local printed = server:p4(
      { 'print', '-q', '//depot/f.txt#' .. r },
      { client = 'alice_ws', cwd = root }
    ).stdout
    H.eq(got, printed)
  end
end

T['timelapse']['view: info panel, stepping, highlights, the cursor stays on the same line'] = function()
  local contents = setup()
  child.cmd('P4 timelapse')
  wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
  local text = info()
  H.neq(text:find('rev 30', 1, true), nil) -- the description
  H.neq(text:find('Changelist: 30', 1, true), nil)
  H.neq(text:find('Submitted by: alice', 1, true), nil)
  H.neq(text:find('Perforce Type: text', 1, true), nil)
  H.neq(text:find('Action: edit', 1, true), nil)
  -- the file's own filetype (whatever this Neovim detects for it; 0.11 has none for .txt)
  H.eq(child.bo.filetype, child.lua_get([[vim.filetype.match({ filename = 'f.txt' }) or '']]))
  H.eq(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n', contents[30])
  -- put the cursor on a line that exists in every revision from 20 to 30 and step back
  local lines30 = vim.split(contents[30], '\n')
  local target
  for i, l in ipairs(lines30) do
    if l:match('^line ') then
      local everywhere = true
      for r = 20, 29 do
        if
          not contents[r]:find('\n' .. l .. '\n', 1, true)
          and not contents[r]:find('^' .. l .. '\n')
        then
          everywhere = false
        end
      end
      if everywhere then
        target = { i, l }
        break
      end
    end
  end
  H.neq(target, nil)
  child.api.nvim_win_set_cursor(0, { target[1], 0 })
  for _ = 1, 10 do
    child.type_keys('h')
  end
  H.neq(info():find('f%.txt#20%f[%D]'), nil)
  H.eq(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n', contents[20])
  H.eq(child.api.nvim_get_current_line(), target[2])
  -- decorations: something added in #20 is highlighted, and #20 deleted something
  local marks = child.lua_get(
    [[vim.tbl_map(function(m) return m[4] end, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.timelapse'], 0, -1, { details = true }))]]
  )
  local hl, virt = false, false
  for _, d in ipairs(marks) do
    hl = hl or d.line_hl_group == 'PerforatedTimelapseAdd'
    virt = virt or d.virt_lines ~= nil
  end
  H.eq(hl or virt, true)
  -- l steps forward again, [R / ]R jump to the ends
  child.type_keys('l')
  H.neq(info():find('f%.txt#21%f[%D]'), nil)
  child.type_keys('[R')
  H.neq(info():find('f%.txt#1%f[%D]'), nil)
  child.type_keys(']R')
  H.neq(info():find('f%.txt#30%f[%D]'), nil)
  -- every step edits the buffer incrementally: walk all revisions down and up again
  for r = 29, 1, -1 do
    child.type_keys('h')
    H.eq(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n', contents[r])
  end
  for r = 2, 30 do
    child.type_keys('l')
    H.eq(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n', contents[r])
  end
  -- r: go to a revision; d: diff it against the previous one
  child.lua([[require('perforated.ui.prompt').input = function(_, cb) cb('#5') end]])
  child.type_keys('r')
  H.neq(info():find('f%.txt#5%f[%D]'), nil)
  child.type_keys('d')
  wait([[#vim.api.nvim_list_tabpages() == 3]]) -- file tab, time-lapse tab, diff tab
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  table.sort(names)
  H.eq(names, { 'perforated:////depot/f.txt#4', 'perforated:////depot/f.txt#5' })
end

T['timelapse']['slider: handles, clicks, diff and range modes'] = function()
  local contents = setup()
  child.cmd('P4 timelapse')
  wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
  local V = [[require('perforated.views.timelapse')._last]]
  local function slider_lines()
    return child.lua_get(
      V .. [[.slider and vim.api.nvim_buf_get_lines(]] .. V .. [[.slider.buf, 0, -1, false)]]
    )
  end
  wait(V .. '.slider ~= nil')
  local sl = slider_lines()
  H.neq(sl[1]:find('●', 1, true), nil)
  -- labels: changelists by default; first, last and the selected one at least
  H.neq(sl[2]:find('30', 1, true), nil)
  H.eq(sl[2]:match('^%s*(%d+)'), '1')
  H.eq(info():find('Comparing', 1, true), nil) -- single mode
  -- a click at the left end of the track goes to the first revision
  H.eq(child.lua_get(V .. '.slider:rev_at(2)'), 1)
  child.lua(
    ('local v = %s; require("perforated.views.timelapse").show(v, v.slider:rev_at(2))'):format(V)
  )
  H.neq(info():find('f%.txt#1%f[%D]'), nil)
  child.type_keys(']R')
  -- m: incremental diff — ◆ (#29) on the left, ● (#30) on the right, in diff mode
  child.type_keys('m')
  wait(V .. '.dwin ~= nil')
  local dbuf = child.lua_get(V .. '.dbuf')
  H.eq(table.concat(child.api.nvim_buf_get_lines(dbuf, 0, -1, false), '\n') .. '\n', contents[29])
  H.eq(child.lua_get('vim.wo[' .. V .. '.dwin].diff'), true)
  H.eq(child.wo.diff, true)
  child.type_keys('[a') -- ◆ back to #28
  H.eq(table.concat(child.api.nvim_buf_get_lines(dbuf, 0, -1, false), '\n') .. '\n', contents[28])
  H.neq(info():find('Comparing: ◆ #28 (CL 28) → ● #30 (CL 30)', 1, true), nil)
  H.neq(slider_lines()[1]:find('◆', 1, true), nil)
  -- m: range — lines added after ◆ carry their revision at the end of the line
  child.type_keys('m')
  wait(V .. '.dwin == nil')
  H.eq(child.wo.diff, false)
  local marks = child.lua_get(
    [[vim.tbl_map(function(m) return m[4] end, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.timelapse'], 0, -1, { details = true }))]]
  )
  local tagged = false
  for _, d in ipairs(marks) do
    if d.virt_text and d.virt_text[1][1]:match('#%d+') then
      tagged = true
    end
  end
  H.eq(tagged or #marks > 0, true)
  child.type_keys('m')
  H.eq(info():find('Comparing', 1, true), nil)
  -- S: revision labels instead of changelists
  child.type_keys('S')
  H.neq(slider_lines()[2]:find('#30', 1, true), nil)
  -- s hides the slider
  child.type_keys('s')
  H.eq(child.lua_get(V .. '.slider'), vim.NIL)
end

T['timelapse']['range: added after ◆ and deleted after ◆'] = function()
  child = H.child()
  local r = child.lua_get([[(function()
    local e = require('perforated.timelapse')
    local tl = vim.tbl_extend('force', { first = 1, last = 3, head = 3, cache = {}, revs = { {}, {}, {} } },
      e.lines({
        { text = 'a', lo = 1, hi = 3 },
        { text = 'b2', lo = 2, hi = 3 },
        { text = 'x', lo = 1, hi = 1 }, -- deleted in 2
        { text = 'y', lo = 1, hi = 2 }, -- deleted in 3
        { text = 'c3', lo = 3, hi = 3 },
      }))
    local added, removed = e.range(tl, 1, 3)
    return { added = added, removed = removed }
  end)()]])
  H.eq(r.added, { { 2, 2 }, { 3, 3 } }) -- b2 (line 2, from #2), c3 (line 3, from #3)
  H.eq(r.removed['3'] or r.removed[3], { { text = 'x', rev = 2 }, { text = 'y', rev = 3 } })
end

T['timelapse']['reopen works; with a global winbar the slider still shows its labels'] = function()
  setup()
  child.o.winbar = 'GLOBAL WINBAR' -- like a winbar plugin
  local V = [[require('perforated.views.timelapse')._last]]
  for _ = 1, 2 do
    child.cmd('P4 timelapse')
    wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
    H.eq(child.lua_get('vim.v.errmsg'), '')
    local sw = child.lua_get(V .. '.slider.win')
    H.eq(child.api.nvim_win_get_height(sw), 3)
    H.neq(child.lua_get(('vim.wo[%d].winbar'):format(sw)):find('Time-lapse', 1, true), nil)
    local lines = child.lua_get(
      V .. '.slider and vim.api.nvim_buf_get_lines(' .. V .. '.slider.buf, 0, -1, false)'
    )
    H.eq(#lines, 2) -- track + labels, both visible under the title
    H.neq(lines[2]:find('30', 1, true), nil)
    -- the details panel: on the right by default, headed "Slider Revision:", one field per line
    local ilines = child.lua_get(('vim.api.nvim_buf_get_lines(%s.ibuf, 0, -1, false)'):format(V))
    H.eq(ilines[1], 'Slider Revision:')
    H.eq(ilines[3], 'Revision: //depot/f.txt#30')
    H.eq(ilines[4], 'Changelist: 30')
    local ipos = child.lua_get(('vim.api.nvim_win_get_position(%s.iwin)'):format(V))
    local mpos = child.lua_get(('vim.api.nvim_win_get_position(%s.win)'):format(V))
    H.eq(ipos[2] > mpos[2], true) -- to the right of the file
    child.type_keys('q')
    H.eq(#child.api.nvim_list_tabpages(), 1)
  end
end

T['timelapse']['info_position = bottom: below the file, two columns, a rule on top'] = function()
  setup()
  child.lua([[require('perforated.config').set({ timelapse = { info_position = 'bottom' } })]])
  child.cmd('P4 timelapse')
  wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
  local V = [[require('perforated.views.timelapse')._last]]
  local iwin = child.lua_get(V .. '.iwin')
  local mwin = child.lua_get(V .. '.win')
  H.eq(child.api.nvim_win_get_position(iwin)[1] > child.api.nvim_win_get_position(mwin)[1], true)
  H.eq(child.api.nvim_win_get_height(iwin), 12)
  H.neq(child.lua_get(('vim.wo[%d].winbar'):format(iwin)):find('─', 1, true), nil)
  local ilines = child.lua_get(('vim.api.nvim_buf_get_lines(%s.ibuf, 0, -1, false)'):format(V))
  H.eq(ilines[1], 'Slider Revision:')
  H.neq(ilines[3]:find('Revision: //depot/f.txt#30', 1, true), nil)
  H.neq(ilines[3]:find('Changelist: 30', 1, true), nil) -- same line: two columns
end

T['timelapse']['anchor: insertions above the cursor keep it on the same line'] = function()
  child = H.child()
  local lnum = child.lua_get([[(function()
    local e = require('perforated.timelapse')
    local tl = vim.tbl_extend('force', {
      first = 1, last = 2, head = 2, cache = {},
      revs = { { rev = '1' }, { rev = '2' } },
    }, e.lines({
        { text = 'new 1', lo = 2, hi = 2 },
        { text = 'a', lo = 1, hi = 2 },
        { text = 'gone', lo = 1, hi = 1 },
        { text = 'b', lo = 1, hi = 2 },
      }))
    return { e.anchor(tl, 1, 3, 2), e.anchor(tl, 1, 2, 2), e.anchor(tl, 2, 1, 1) }
  end)()]])
  -- b: line 3 in #1 → line 3 in #2; 'gone' (line 2 in #1) → next line 'b' (3); 'new 1' → 'a' (1)
  H.eq(lnum, { 3, 3, 1 })
end

T['timelapse']['parse: a line without a newline is its own entry, long lines still join'] = function()
  child = H.child()
  local got = child.lua_get([[(function()
    local out = {}
    local l = require('perforated.timelapse').parse({
      { data = 'a\n', lower = '1', upper = '2' },
      { data = 'foo', lower = '1', upper = '1' },
      { data = 'foo\n', lower = '2', upper = '2' },
      { data = 'long ', lower = '2', upper = '2' },
      { data = 'line\n', lower = '2', upper = '2' },
    })
    for i, t in ipairs(l.text) do
      out[#out + 1] = ('%s %d-%d'):format(t, l.lo[i], l.hi[i])
    end
    return out
  end)()]])
  H.eq(got, { 'a 1-2', 'foo 1-1', 'foo 2-2', 'long line 2-2' })
end

T['timelapse']['a revision without a final newline rebuilds correctly (real p4d)'] = function()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, { ['g.txt'] = 'a\nfoo' }, 'rev 1')
  server:p4({ 'edit', root .. '/g.txt' }, { client = 'alice_ws', cwd = root })
  H.write(root .. '/g.txt', 'a\nfoo\nbar\n')
  server:p4({ 'submit', '-d', 'rev 2' }, { client = 'alice_ws', cwd = root })
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = { p4 = P.p4, poll = { interval = 0 }, startup_check = false },
  })
  child.cmd('edit ' .. root .. '/g.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.lua(([[
    _G.tl = nil
    require('perforated.timelapse').load(require('perforated').workspace(), %q, function(tl, err)
      _G.tl, _G.err = tl or false, err
    end)
  ]]):format(root .. '/g.txt'))
  wait('_G.tl ~= nil')
  local rev = 'require("perforated.timelapse").revision(_G.tl, %d)'
  H.eq(child.lua_get(rev:format(1)), { 'a', 'foo' })
  H.eq(child.lua_get(rev:format(2)), { 'a', 'foo', 'bar' })
end

--- Every revision rebuilt from a loaded time-lapse (`_G.tl`) equals `p4 print` (empty when the
--- revision deletes the file).
local function check_all(revs)
  for r = 1, revs do
    local got = child.lua_get(
      ('table.concat(require("perforated.timelapse").revision(_G.tl, %d), "\\n")'):format(r)
    )
    local printed = server:p4(
      { 'print', '-q', '//depot/f.txt#' .. r },
      { client = 'alice_ws', cwd = root }
    )
    local want = printed.code == 0 and printed.stdout:gsub('\n$', '') or ''
    H.eq({ r, got }, { r, want })
  end
end

--- The `annotate` calls in the log, as their file arguments.
local function annotates()
  return child.lua_get([[(function()
    local out = {}
    for _, e in ipairs(require('perforated.core.log').entries()) do
      if vim.tbl_contains(e.argv, 'annotate') then
        out[#out + 1] = e.argv[#e.argv]
      end
    end
    return out
  end)()]])
end

T['timelapse']['a long history: the newest revisions first, the rest stitched on (real p4d)'] = function()
  -- 20 edits, a delete at #21, re-added at #22, edits to #25. A window of 5 starts at #21,
  -- which has no content: the first part holds #22..#25.
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  local contents = revisions(25)
  local o = { client = 'alice_ws', cwd = root }
  server:submit_files('alice_ws', root, { ['f.txt'] = contents[1] }, 'rev 1')
  for r = 2, 25 do
    if r == 21 then
      server:p4({ 'delete', root .. '/f.txt' }, o)
    else
      if r ~= 22 then
        server:p4({ 'edit', root .. '/f.txt' }, o)
      end
      H.write(root .. '/f.txt', contents[r])
      if r == 22 then
        server:p4({ 'add', root .. '/f.txt' }, o)
      end
    end
    server:p4({ 'submit', '-d', 'rev ' .. r }, o)
  end
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      timelapse = { window = 5 },
    },
  })
  child.cmd('edit ' .. root .. '/f.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.wait_idle(child)
  child.lua([[require('perforated.core.log').clear()]])
  child.lua(([[
    _G.tl, _G.first_part, _G.more = nil, nil, nil
    local e = require('perforated.timelapse')
    e.load(require('perforated').workspace(), %q, function(tl, err)
      _G.tl, _G.err = tl or false, err
      if tl then
        _G.first_part = { from = tl.from, loaded21 = e.loaded(tl, 21), loaded22 = e.loaded(tl, 22),
          r25 = table.concat(e.revision(tl, 25), '\n') }
      end
    end, { on_more = function(tl, err) _G.more = { ok = tl ~= nil, err = err, from = tl and tl.from } end })
  ]]):format(root .. '/f.txt'))
  wait('_G.more ~= nil')
  H.eq(child.lua_get('_G.err'), vim.NIL)
  local fp = child.lua_get('_G.first_part')
  H.eq({ fp.from, fp.loaded21, fp.loaded22 }, { 22, false, true })
  H.eq(fp.r25 .. '\n', contents[25])
  H.eq(child.lua_get('_G.more'), { ok = true, from = 1 })
  H.eq(H.p4_subcommands(child), { 'filelog', 'annotate', 'annotate' })
  H.eq(annotates(), { '//depot/f.txt#21,#25', '//depot/f.txt#1,#22' })
  check_all(25)
end

T['timelapse']['a closed time-lapse reopens from memory; after a submit only the new revision is annotated'] = function()
  setup()
  local V = [[require('perforated.views.timelapse')._last]]
  child.cmd('P4 timelapse')
  wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
  child.type_keys('q')
  H.eq(#child.lua_get([[require('perforated.timelapse').kept()]]), 1)
  H.wait_idle(child)
  child.lua([[require('perforated.core.log').clear()]])
  child.cmd('P4 timelapse')
  wait(INFO .. [[:find('f%.txt#30%f[%D]') ~= nil]])
  H.eq(H.p4_subcommands(child), { 'filelog' })
  H.eq(#child.lua_get([[require('perforated.timelapse').kept()]]), 0) -- the view holds it
  child.type_keys('q')
  -- a new revision elsewhere: the kept copy is extended by an annotate of #30..#31 alone
  local o = { client = 'alice_ws', cwd = root }
  server:p4({ 'edit', root .. '/f.txt' }, o)
  H.write(root .. '/f.txt', 'brand new\n' .. table.concat({}, ''))
  server:p4({ 'submit', '-d', 'rev 31' }, o)
  H.wait_idle(child)
  child.lua([[require('perforated.core.log').clear()]])
  child.cmd('P4 timelapse //depot/f.txt')
  wait(INFO .. [[:find('f%.txt#31%f[%D]') ~= nil]])
  H.eq(H.p4_subcommands(child), { 'filelog', 'annotate' })
  H.eq(annotates(), { '//depot/f.txt#30,#31' })
  child.lua('_G.tl = ' .. V .. '.tl')
  check_all(31)
end

T['timelapse']['stitch refuses two parts that disagree on the joining revision'] = function()
  child = H.child()
  local r = child.lua_get([[(function()
    local e = require('perforated.timelapse')
    local a = e.lines({ { text = 'x', lo = 1, hi = 2 }, { text = 'y', lo = 1, hi = 2 } })
    local ok = e.lines({ { text = 'x', lo = 2, hi = 3 }, { text = 'y', lo = 2, hi = 2 },
      { text = 'z', lo = 3, hi = 3 } })
    local bad = e.lines({ { text = 'x', lo = 2, hi = 3 }, { text = 'q', lo = 2, hi = 3 } })
    local s = e.stitch(a, ok, 2)
    return { s.text, s.lo, s.hi, e.stitch(a, bad, 2) == nil }
  end)()]])
  H.eq(r, { { 'x', 'y', 'z' }, { 1, 1, 3 }, { 3, 2, 3 }, true })
end

--- A fake workspace whose `//depot/f.txt` has three revisions ('a' / 'a b' / 'a b c').
local function fake_setup(rules, config)
  local froot = H.tmp()
  H.write(froot .. '/.p4config', 'P4PORT=fake:1666\n')
  local filelog = {
    depotFile = '//depot/f.txt',
    rev0 = '3',
    change0 = '13',
    action0 = 'edit',
    type0 = 'text',
    time0 = '1700000300',
    user0 = 'u',
    client0 = 'c',
    desc0 = 'three',
    fileSize0 = '6',
    digest0 = 'C',
    rev1 = '2',
    change1 = '12',
    action1 = 'edit',
    type1 = 'text',
    time1 = '1700000200',
    user1 = 'u',
    client1 = 'c',
    desc1 = 'two',
    fileSize1 = '4',
    digest1 = 'B',
    rev2 = '1',
    change2 = '11',
    action2 = 'add',
    type2 = 'text',
    time2 = '1700000100',
    user2 = 'u',
    client2 = 'c',
    desc2 = 'one',
    fileSize2 = '2',
    digest2 = 'A',
  }
  local head = { depotFile = '//depot/f.txt', rev = '3', change = '13', action = 'edit' }
  local list = {
    { match = '^filelog', records = { filelog }, sleep = rules.filelog_sleep },
  }
  vim.list_extend(list, rules)
  vim.list_extend(list, {
    {
      match = '^annotate %-a %-q //depot/f%.txt#3$',
      sleep = rules.annotate_sleep,
      records = {
        head,
        { data = 'a\n', lower = '1', upper = '3' },
        { data = 'b\n', lower = '2', upper = '3' },
        { data = 'c\n', lower = '3', upper = '3' },
      },
    },
    { match = '.', records = {} },
  })
  child = H.child({
    fake = { rules = list },
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_extend('force', { p4 = H.fake_p4 }, config or {}),
  })
  child.lua(([[_G.ws = require('perforated.core.activation').for_dir(%q)]]):format(froot))
  H.wait_idle(child)
end

T['timelapse fake'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['timelapse fake']['with the head known, the annotate runs alongside filelog'] = function()
  fake_setup({ filelog_sleep = 0.8, annotate_sleep = 0.8 })
  local ms = child.lua_get([[(function()
    local t0 = vim.uv.hrtime()
    local done
    require('perforated.timelapse').load(_G.ws, '//depot/f.txt', function(tl) done = tl end,
      { head = { rev = 3, action = 'edit' } })
    vim.wait(5000, function() return done ~= nil end, 10)
    return done and (vim.uv.hrtime() - t0) / 1e6 or -1
  end)()]])
  H.eq(ms > 0 and ms < 1400, true) -- one after the other would take 1.6 s
  local calls = vim.tbl_map(function(c)
    return c.cmd
  end, H.calls(child.fake.log))
  calls = vim.tbl_filter(function(c)
    return c:match('^filelog') or c:match('^annotate')
  end, calls)
  table.sort(calls)
  H.eq(calls, { 'annotate -a -q //depot/f.txt#3', 'filelog -l //depot/f.txt' })
end

T['timelapse fake']['closing the tab while it loads stops the annotate'] = function()
  fake_setup({ { match = '^annotate', hang = true } })
  child.lua([[require('perforated.views.timelapse').open(_G.ws, '//depot/f.txt')]])
  H.eq(
    H.wait(
      child,
      [[require('perforated.core.queue').global().running == 1
    and #vim.tbl_filter(function(e) return vim.tbl_contains(e.argv, 'annotate') end,
      require('perforated.core.log').entries()) == 0]],
      5000
    ),
    true
  )
  vim.uv.sleep(300) -- the annotate is running
  child.cmd('bwipeout!')
  H.eq(H.wait(child, [[require('perforated.core.queue').global().running == 0]], 5000), true)
  H.eq(
    child.lua_get(
      [[require('perforated.core.log').entries()[#require('perforated.core.log').entries()].err]]
    ),
    'cancelled'
  )
end

T['timelapse fake']['older revisions wait for the background part; the slider says so'] = function()
  fake_setup({
    {
      match = '^annotate %-a %-q //depot/f%.txt#2,#3$',
      records = {
        { depotFile = '//depot/f.txt', rev = '3' },
        { data = 'a\n', lower = '2', upper = '3' },
        { data = 'b\n', lower = '2', upper = '3' },
        { data = 'c\n', lower = '3', upper = '3' },
      },
    },
    { match = '^annotate %-a %-q //depot/f%.txt#1,#2$', hang = true },
  }, { timelapse = { window = 2 } })
  child.o.lines, child.o.columns = 30, 160
  child.lua([[
    local toast = require('perforated.ui.toast')
    _G.notes = {}
    local notify = toast.notify
    toast.notify = function(msg, ...) table.insert(_G.notes, msg); return notify(msg, ...) end
    require('perforated.views.timelapse').open(_G.ws, '//depot/f.txt')
  ]])
  local V = [[require('perforated.views.timelapse')._last]]
  H.eq(H.wait(child, V .. '.tl ~= nil and ' .. V .. '.slider ~= nil', 5000), true)
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'a', 'b', 'c' })
  local bar = child.lua_get(('vim.wo[%s.slider.win].winbar'):format(V))
  H.neq(bar:find('loading revisions before #2', 1, true), nil)
  H.neq(
    child
      .lua_get(('vim.api.nvim_buf_get_lines(%s.slider.buf, 0, 1, false)[1]'):format(V))
      :find('┄', 1, true),
    nil
  )
  -- #3 shows c as added; #2 (the oldest loaded) can't say what it changed yet
  child.type_keys('h')
  H.eq(child.lua_get(V .. '.n'), 2)
  H.eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'a', 'b' })
  H.eq(
    child.lua_get(
      [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['perforated.timelapse'], 0, -1, {})]]
    ),
    0
  )
  child.type_keys('h')
  H.eq(child.lua_get(V .. '.n'), 2)
  H.eq(
    child.lua_get('_G.notes'),
    { '[perforated] older revisions (before #2) are still loading…' }
  )
end

return T
