-- End-to-end tests against a real, throwaway p4d (rsh mode). Skipped when binaries are missing
-- (run `make deps`).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, ws_root

local function setup_workspace()
  server = P.new()
  ws_root = server.dir .. '/ws'
  server:client('alice_ws', ws_root)
  server:submit_files(
    'alice_ws',
    ws_root,
    { ['src/a.txt'] = 'hello\n', ['b.txt'] = 'b\n' },
    'initial'
  )
  server:p4config(ws_root, 'alice_ws')
end

T['real p4d'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not found in ' .. P.bin_dir .. ' (make deps)')
      end
      setup_workspace()
      child = H.child({ env = { P4CONFIG = '.p4config' }, config = { p4 = P.p4 } })
    end,
    post_case = function()
      if child then
        child.stop()
      end
    end,
  },
})

T['real p4d']['activates, learns client/root, runs batched fstat from the anchor'] = function()
  child.cmd('edit ' .. ws_root .. '/src/a.txt')
  H.eq(child.lua_get('vim.b.perforated_ws'), ws_root)
  H.eq(
    H.wait(
      child,
      [[require('perforated').workspace().info ~= nil and require('perforated').workspace().settings ~= nil]],
      15000
    ),
    true
  )
  H.eq(child.lua_get([[require('perforated').workspace():client()]]), 'alice_ws')
  H.eq(child.lua_get([[require('perforated').workspace().root]]), ws_root)
  H.eq(child.lua_get([[require('perforated').workspace():user()]]), 'alice')
  H.eq(child.lua_get([[require('perforated').workspace().conn.state]]), 'online')

  child.lua(
    [[
    _G.res = nil
    require('perforated').workspace():run({ '-x', '-', 'fstat', '-T', 'depotFile,haveRev,headRev' },
      { stdin = ... }, function(r) _G.res = r end)
  ]],
    { { ws_root .. '/src/a.txt', ws_root .. '/b.txt', ws_root .. '/missing.txt' } }
  )
  H.eq(H.wait(child, '_G.res ~= nil', 15000), true)
  local res = child.lua_get('_G.res')
  H.eq(res.ok, true)
  H.eq(#res.records, 2)
  H.eq(res.records[1].depotFile, '//depot/src/a.txt')
  H.eq(res.records[1].haveRev, '1')
  H.eq(#res.warnings, 1) -- missing.txt - no such file(s)
end

T['real p4d'][':P4 info and :checkhealth report the workspace'] = function()
  child.cmd('edit ' .. ws_root .. '/b.txt')
  child.cmd('P4 info')
  H.eq(
    H.wait(
      child,
      [[vim.api.nvim_exec2('messages', { output = true }).output:find('alice_ws', 1, true)]],
      15000
    ),
    true
  )
  child.cmd('checkhealth perforated')
  local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  H.expect.no_equality(text:find('Client alice_ws', 1, true), nil)
  H.expect.no_equality(text:find('Logged in', 1, true), nil)
  H.eq(text:find('ERROR', 1, true), nil)
end

T['real p4d']['expired login → prompt → login → retried call succeeds'] = function()
  server:p4({ 'passwd' }, { stdin = 'Secret123\nSecret123\n' })
  child.cmd('edit ' .. ws_root .. '/b.txt')
  child.lua([[
    _G.prompts = 0
    vim.fn.inputsecret = function() _G.prompts = _G.prompts + 1; return 'Secret123' end
    _G.res = nil
    require('perforated').workspace():run({ 'opened' }, {}, function(r) _G.res = r end)
  ]])
  H.eq(H.wait(child, '_G.res ~= nil', 20000), true)
  H.eq(child.lua_get('_G.res.ok'), true)
  H.eq(child.lua_get('_G.prompts'), 1)
  H.eq(child.lua_get([[require('perforated').workspace().conn.state]]), 'online')
end

T['real p4d']['a stray P4DIFF in the environment cannot hang internal calls'] = function()
  child.stop()
  child = H.child({
    env = { P4CONFIG = '.p4config', P4DIFF = 'sleep 600', P4PAGER = 'sleep 600' },
    config = { p4 = P.p4 },
  })
  server:p4({ 'edit', ws_root .. '/b.txt' }, { client = 'alice_ws', cwd = ws_root })
  H.write(ws_root .. '/b.txt', 'changed\n')
  child.cmd('edit ' .. ws_root .. '/b.txt')
  child.lua([[
    _G.res = nil
    -- `p4 diff` (without -s flags) consults P4DIFF; internally it must be neutralised.
    require('perforated').workspace():run({ 'diff', '-du' }, { timeout = 8000 }, function(r) _G.res = r end)
  ]])
  H.eq(H.wait(child, '_G.res ~= nil', 15000), true)
  H.eq(child.lua_get('_G.res.timed_out'), false)
end

return T
