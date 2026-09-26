-- M5: time-lapse (real p4d).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
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

T['timelapse']['view: winbar, stepping, highlights, the cursor stays on the same line'] = function()
  local contents = setup()
  child.cmd('P4 timelapse')
  wait([[vim.wo.winbar:find('#30/#30', 1, true) ~= nil]])
  H.neq(child.wo.winbar:find('rev 30', 1, true), nil)
  H.eq(child.bo.filetype, 'text')
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
  H.neq(child.wo.winbar:find('#20/#30', 1, true), nil)
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
  H.neq(child.wo.winbar:find('#21/#30', 1, true), nil)
  child.type_keys('[R')
  H.neq(child.wo.winbar:find('#1/#30', 1, true), nil)
  child.type_keys(']R')
  H.neq(child.wo.winbar:find('#30/#30', 1, true), nil)
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
  H.neq(child.wo.winbar:find('#5/#30', 1, true), nil)
  child.type_keys('d')
  wait([[#vim.api.nvim_list_tabpages() == 3]]) -- file tab, time-lapse tab, diff tab
  local names = child.lua_get(
    [[vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_tabpage_list_wins(0))]]
  )
  table.sort(names)
  H.eq(names, { 'perforated:////depot/f.txt#4', 'perforated:////depot/f.txt#5' })
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
