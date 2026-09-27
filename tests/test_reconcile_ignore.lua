-- The reconcile scan honours P4IGNORE files above the scanned directory (real p4d).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

T['reconcile honours P4IGNORE above the scan root'] = function()
  local server = P.new()
  local root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, { ['src/a.c'] = 'a\n' }, 'initial')
  server:p4config(root, 'alice_ws')
  H.write(root .. '/.p4ignore', '*.log\n')
  H.write(root .. '/src/junk.log', 'x\n')
  H.write(root .. '/src/new.c', 'x\n')
  local child = H.child({
    env = { P4CONFIG = '.p4config', P4IGNORE = '.p4ignore' },
    config = { p4 = P.p4, poll = { interval = 0 } },
  })
  child.cmd('edit ' .. root .. '/src/a.c')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000)
  child.lua([[
    _G.out = nil
    local ws = require('perforated').workspace()
    local cv = require('perforated.views.client')
    require('perforated.changelists').status(ws, cv.reconcile_args(ws, { 'src' }), function(recs, err)
      local names = {}
      for _, r in ipairs(recs or {}) do names[#names + 1] = r.clientFile or r.depotFile end
      table.sort(names)
      _G.out = { names = names, err = err }
    end)
  ]])
  H.wait(child, '_G.out ~= nil', 15000)
  local out = child.lua_get('_G.out')
  child.stop()
  H.eq(#out.names, 1)
end

return T
