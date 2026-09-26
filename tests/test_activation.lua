local H = require('tests.helpers')
local T = MiniTest.new_set()

local child

local function info_rules(root, client)
  return {
    {
      match = '^info',
      records = {
        {
          clientName = client or 'ws1',
          clientRoot = root,
          userName = 'alice',
          serverVersion = 'P4D/FAKE/2025.2/0',
          caseHandling = 'sensitive',
        },
      },
    },
    { match = '^set', stdout = 'P4CLIENT=' .. (client or 'ws1') .. '\nP4USER=alice\n' },
  }
end

local function edit(path)
  child.cmd('edit ' .. vim.fn.fnameescape(path))
end

local function ws_key(buf)
  return child.lua_get(('vim.b[%d].perforated_ws'):format(buf or 0))
end

T['dormant'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['dormant']['no P4CONFIG/P4CLIENT: nothing loads, no processes, autocmd removed'] = function()
  child = H.child({ fake = { rules = {} } })
  local dir = H.tmp()
  H.write(dir .. '/a.txt', 'x')
  edit(dir .. '/a.txt')
  H.eq(H.loaded_modules(child), { 'perforated.gate' })
  H.eq(#H.calls(child.fake.log), 0)
  H.eq(child.lua_get([[#vim.api.nvim_get_autocmds({ group = 'perforated' })]]), 0)
  -- Commands still exist.
  H.eq(child.fn.exists(':P4'), 2)
  H.eq(child.fn.exists(':P4info'), 0) -- aliases are defined on first use
  child.cmd('P4info')
  H.eq(child.fn.exists(':P4info'), 2)
end

T['dormant']['P4CONFIG set but file outside any workspace: nothing loads'] = function()
  child = H.child({ fake = { rules = {} }, env = { P4CONFIG = '.p4config' } })
  local dir = H.tmp()
  H.write(dir .. '/a.txt', 'x')
  edit(dir .. '/a.txt')
  H.eq(H.loaded_modules(child), { 'perforated.gate' })
  H.eq(#H.calls(child.fake.log), 0)
  H.eq(ws_key(), vim.NIL)
end

T['dormant']['p4 missing: stays dormant even inside a workspace'] = function()
  local dir = H.tmp()
  H.write(dir .. '/.p4config', 'P4CLIENT=x\n')
  H.write(dir .. '/a.txt', 'x')
  child = H.child({ env = { P4CONFIG = '.p4config' }, config = { p4 = '/nonexistent/p4' } })
  edit(dir .. '/a.txt')
  H.eq(H.loaded_modules(child), { 'perforated.gate' })
  H.eq(ws_key(), vim.NIL)
end

T['workspaces'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['workspaces']['buffers of one workspace share one object and one info call'] = function()
  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  child = H.child({ fake = { rules = info_rules(root) }, env = { P4CONFIG = '.p4config' } })
  for i = 1, 15 do
    local p = ('%s/src/d%d/f%d.c'):format(root, i % 3, i)
    H.write(p, 'x')
    edit(p)
  end
  H.eq(
    H.wait(
      child,
      ([[require('perforated.core.workspace').get(%q).settings ~= nil
      and require('perforated.core.workspace').get(%q).info ~= nil]]):format(root, root)
    ),
    true
  )
  H.eq(child.lua_get([[#require('perforated.core.workspace').list()]]), 1)
  H.eq(
    child.lua_get(
      ([[vim.tbl_count(require('perforated.core.workspace').get(%q).buffers)]]):format(root)
    ),
    15
  )
  H.eq(#H.calls_matching(child.fake.log, 'info'), 1)
  H.eq(#H.calls_matching(child.fake.log, 'set'), 1)
  for _, c in ipairs(H.calls(child.fake.log)) do
    H.eq(c.cwd, root)
    H.eq(c.env.PWD, root)
  end
  H.eq(ws_key(), root)
end

T['workspaces']['different anchors are different workspaces; nested P4CONFIG wins'] = function()
  local a, b = H.tmp(), H.tmp()
  H.write(a .. '/.p4config', 'P4CLIENT=a\n')
  H.write(b .. '/.p4config', 'P4CLIENT=b\n')
  H.write(a .. '/sub/.p4config', 'P4CLIENT=nested\n')
  child = H.child({ fake = { rules = info_rules('/r') }, env = { P4CONFIG = '.p4config' } })
  for _, p in ipairs({ a .. '/x.c', b .. '/y.c', a .. '/sub/deep/z.c' }) do
    H.write(p, 'x')
    edit(p)
  end
  H.eq(
    child.lua_get(
      [[vim.tbl_map(function(w) return w.key end, require('perforated.core.workspace').list())]]
    ),
    vim.fn.sort({ a, b, a .. '/sub' })
  )
  H.eq(ws_key(), a .. '/sub')
  H.eq(
    H.wait(
      child,
      [[vim.iter(require('perforated.core.workspace').list()):all(function(w)
    return w.info ~= nil and w.settings ~= nil end)]]
    ),
    true
  )
  local cwds = {}
  for _, c in ipairs(H.calls(child.fake.log)) do
    cwds[c.cwd] = true
  end
  H.eq(cwds, { [a] = true, [b] = true, [a .. '/sub'] = true })
end

T['workspaces']['environment-only setup: one p4 info learns the root'] = function()
  local root = H.tmp()
  local outside = H.tmp()
  child = H.child({ fake = { rules = info_rules(root, 'envws') }, env = { P4CLIENT = 'envws' } })
  H.write(root .. '/a.c', 'x')
  H.write(root .. '/b/c.c', 'x')
  H.write(outside .. '/o.c', 'x')
  edit(root .. '/a.c')
  local a = child.api.nvim_get_current_buf()
  edit(root .. '/b/c.c')
  edit(outside .. '/o.c')
  H.eq(H.wait(child, ('vim.b[%d].perforated_ws ~= nil'):format(a)), true)
  H.eq(ws_key(a), root)
  H.eq(ws_key(), vim.NIL)
  -- One info for detection (connection context) + set/info for the workspace itself.
  H.eq(
    H.wait(
      child,
      ([[(require('perforated.core.workspace').get(%q) or {}).settings ~= nil]]):format(root)
    ),
    true
  )
  H.eq(#H.calls_matching(child.fake.log, 'set'), 1)
  H.eq(#H.calls_matching(child.fake.log, 'info') <= 2, true)
end

T['workspaces']['goes idle when its last buffer closes and cwd is outside'] = function()
  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(root .. '/a.c', 'x')
  child = H.child({ fake = { rules = info_rules(root) }, env = { P4CONFIG = '.p4config' } })
  edit(root .. '/a.c')
  child.cmd('bwipeout')
  H.eq(child.lua_get(([[require('perforated.core.workspace').get(%q).idle]]):format(root)), true)
  -- Reopening reactivates the same object.
  edit(root .. '/a.c')
  H.eq(child.lua_get(([[require('perforated.core.workspace').get(%q).idle]]):format(root)), false)
end

T['commands'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['commands']['connection-only command works outside a workspace'] = function()
  child = H.child({
    fake = {
      rules = {
        {
          match = '^info',
          records = { { clientName = '*unknown*', serverVersion = 'P4D/FAKE', userName = 'alice' } },
        },
        { match = '^set', stdout = 'P4USER=alice\n' },
      },
    },
  })
  child.cmd('P4 info')
  H.eq(
    H.wait(
      child,
      [[vim.api.nvim_exec2('messages', { output = true }).output:find('connection only', 1, true)]]
    ),
    true
  )
end

T['commands']['workspace-only scope is refused outside a workspace'] = function()
  child = H.child({ fake = { rules = {} } })
  child.lua([[
    _G.called = false
    require('perforated.commands').resolve('workspace', function() _G.called = true end)
  ]])
  H.eq(child.lua_get('_G.called'), false)
  H.expect.no_equality(
    child.cmd_capture('messages'):find('not in a Perforce workspace', 1, true),
    nil
  )
end

T['commands']['plugin/ subcommand list matches the command table'] = function()
  child = H.child()
  local src = table.concat(vim.fn.readfile(H.root .. '/plugin/perforated.lua'), '\n')
  local list = src:match('local subs = (%b{})')
  local subs = loadstring('return ' .. list)()
  table.sort(subs)
  H.eq(subs, child.lua_get([[require('perforated.commands').names()]]))
end

T['commands']['completion'] = function()
  child = H.child()
  H.eq(child.fn.getcompletion('P4 lo', 'cmdline'), { 'log', 'login', 'lookup' })
end

return T
