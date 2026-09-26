-- M6: p4vc escape hatches, timings, memory soak (real p4d unless noted).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root, log

local function wait(expr, ms)
  H.eq(H.wait(child, expr, ms or 15000), true)
end

local function setup(config)
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, { ['a.txt'] = 'a\n', ['b.txt'] = 'b\n' }, 'initial')
  server:p4({ 'edit', root .. '/b.txt' }, { client = 'alice_ws', cwd = root })
  server:p4config(root, 'alice_ws')
  log = server.dir .. '/p4vc.log'
  child = H.child({
    env = { P4CONFIG = '.p4config', FAKE_P4VC_LOG = log },
    config = vim.tbl_deep_extend('force', {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      p4vc = H.root .. '/tests/bin/fake-p4vc',
    }, config or {}),
  })
  child.cmd('edit ' .. root .. '/a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
end

local function p4vc_calls()
  local ok, lines = pcall(vim.fn.readfile, log)
  return ok and lines or {}
end

T['m6'] = MiniTest.new_set({
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

T['m6']['p4vc: :P4 p4vc revgraph (current file), gR in the client view, health'] = function()
  setup()
  child.cmd('P4 p4vc revgraph')
  H.eq(
    vim.wait(5000, function()
      return #p4vc_calls() == 1
    end, 50),
    true
  )
  H.eq(p4vc_calls()[1], 'revgraph //depot/a.txt|' .. root)
  child.cmd('P4')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('b.txt', 1, true) ~= nil]]
  )
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find('b.txt', 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  child.type_keys('gR')
  H.eq(
    vim.wait(5000, function()
      return #p4vc_calls() == 2
    end, 50),
    true
  )
  H.eq(p4vc_calls()[2], 'revgraph //depot/b.txt|' .. root)
  child.cmd('checkhealth perforated')
  H.neq(
    table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('p4vc: ', 1, true),
    nil
  )
end

T['m6']['p4vc missing: actions hidden, command explains'] = function()
  setup({ p4vc = '/nonexistent/p4vc' })
  child.cmd('P4')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('b.txt', 1, true) ~= nil]]
  )
  local valid = child.lua_get([[(function()
    local v = require('perforated.views.client')._get(require('perforated').workspace().key)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)) do
      if l:find('b.txt', 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
    end
    return vim.tbl_map(function(a) return a.id end, require('perforated.ui.keys').valid(v.actions, v.tree:node_at()))
  end)()]])
  H.eq(vim.tbl_contains(valid, 'revgraph'), false)
end

T['m6'][':P4 debug timings lists p4 commands and plugin timings'] = function()
  setup()
  child.cmd('P4')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('b.txt', 1, true) ~= nil]]
  )
  child.cmd('P4 debug timings')
  local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  H.neq(text:find('fstat', 1, true), nil)
  H.neq(text:find('client view: refresh', 1, true), nil)
  H.neq(text:find('Lua memory', 1, true), nil)
end

T['m6']['memory soak: opening and closing 1000 files returns to baseline'] = function()
  server = P.new()
  root = server.dir .. '/ws'
  server:client('alice_ws', root)
  local files = {}
  for i = 1, 1000 do
    files[('d%d/f%d.c'):format(i % 20, i)] = 'int x = ' .. i .. ';\n'
  end
  server:submit_files('alice_ws', root, files, 'many files')
  server:p4config(root, 'alice_ws')
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = { p4 = P.p4, poll = { interval = 0 }, startup_check = false },
  })
  local function cycle(from, to)
    child.lua(([[
      for i = %d, %d do
        vim.cmd('edit ' .. vim.fn.fnameescape(%q .. ('/d%%d/f%%d.c'):format(i %% 20, i)))
        vim.cmd('bwipeout')
      end
    ]]):format(from, to, root))
    -- let every fstat batch come back (buffers are gone by then)
    vim.uv.sleep(200)
    H.eq(
      H.wait(
        child,
        [[(function() local q = require('perforated.core.queue').global(); return q:pending_count() == 0 and (q.running or 0) == 0 end)()]],
        30000
      ),
      true
    )
    vim.uv.sleep(300)
  end
  local gc = [[collectgarbage(); collectgarbage(); return collectgarbage('count')]]
  -- Control: the same cycles outside any workspace (the plugin stays dormant), to separate
  -- Neovim's own per-buffer growth from ours.
  local outside = H.tmp()
  for i = 1, 1000 do
    H.write(('%s/d%d/f%d.c'):format(outside, i % 20, i), 'x\n')
  end
  local function control(from, to)
    child.lua(([[
      for i = %d, %d do
        vim.cmd('edit ' .. vim.fn.fnameescape(%q .. ('/d%%d/f%%d.c'):format(i %% 20, i)))
        vim.cmd('bwipeout')
      end
    ]]):format(from, to, outside))
  end
  control(1, 20)
  local c0 = child.lua(gc)
  control(21, 1000)
  local neovim_growth = child.lua(gc) - c0
  cycle(1, 20) -- warm up: modules, the workspace, caches
  local before = child.lua(gc)
  cycle(21, 1000)
  local after = child.lua(gc)
  local left = child.lua_get(
    [[{ vim.tbl_count(require('perforated.buffer').all()), vim.tbl_count(require('perforated.core.workspace').list()[1].fstat), #require('perforated.core.log').entries(), vim.tbl_count(require('perforated.core.workspace').list()[1].buffers or {}) }]]
  )
  H.eq(left[1], 0)
  H.eq(left[2], 0)
  local ours = (after - before) - neovim_growth
  if ours >= 100 then
    error(
      ('Lua memory grew %.0f KB over 980 open/close cycles (Neovim alone: %.0f KB)'):format(
        after - before,
        neovim_growth
      )
    )
  end
end

return T
