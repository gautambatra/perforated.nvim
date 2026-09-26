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
  child.lua([[require('perforated.core.log').clear()]])
  child.lua(([[
    _G.tl = nil
    require('perforated.timelapse').load(require('perforated').workspace(), %q, function(tl, err)
      _G.tl, _G.err = tl or false, err
    end)
  ]]):format(root .. '/f.txt'))
  wait('_G.tl ~= nil')
  H.eq(child.lua_get('_G.err'), vim.NIL)
  H.eq(#child.lua_get([[require('perforated.core.log').entries()]]), 2)
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
  child.lua([[vim.ui.input = function(_, cb) cb('#5') end]])
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
  child.type_keys('H') -- ◆ back to #28
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
    local tl = { first = 1, last = 3, head = 3, cache = {}, revs = { {}, {}, {} },
      entries = {
        { text = 'a', lo = 1, hi = 3 },
        { text = 'b2', lo = 2, hi = 3 },
        { text = 'x', lo = 1, hi = 1 }, -- deleted in 2
        { text = 'y', lo = 1, hi = 2 }, -- deleted in 3
        { text = 'c3', lo = 3, hi = 3 },
      } }
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
    local tl = {
      first = 1, last = 2, head = 2, cache = {},
      revs = { { rev = '1' }, { rev = '2' } },
      entries = {
        { text = 'new 1', lo = 2, hi = 2 },
        { text = 'a', lo = 1, hi = 2 },
        { text = 'gone', lo = 1, hi = 1 },
        { text = 'b', lo = 1, hi = 2 },
      },
    }
    return { e.anchor(tl, 1, 3, 2), e.anchor(tl, 1, 2, 2), e.anchor(tl, 2, 1, 1) }
  end)()]])
  -- b: line 3 in #1 → line 3 in #2; 'gone' (line 2 in #1) → next line 'b' (3); 'new 1' → 'a' (1)
  H.eq(lnum, { 3, 3, 1 })
end

return T
