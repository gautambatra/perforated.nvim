-- The reconcile scan (real p4d): P4IGNORE files above the scanned directory, and `status -m`.
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

-- A client with src/a.c synced, a child on it, and a scan helper (`_G.scan(paths)`: the names
-- the reconcile preview found, and the `p4 status` argument lists it ran).
local function scan_setup(config)
  local server = P.new()
  local root = server.dir .. '/ws'
  server:client('alice_ws', root)
  server:submit_files('alice_ws', root, { ['src/a.c'] = 'one\n' }, 'initial')
  server:p4config(root, 'alice_ws')
  local child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_deep_extend('force', { p4 = P.p4, poll = { interval = 0 } }, config or {}),
  })
  child.cmd('edit ' .. root .. '/src/a.c')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000)
  child.lua([[
    local ws = require('perforated').workspace()
    _G.status_args = {}
    local run = ws.run
    ws.run = function(self, args, ...)
      if args[1] == 'status' then
        table.insert(_G.status_args, vim.list_slice(args, 1, #args - 1))
        if _G.reject_m and vim.tbl_contains(args, '-m') then
          local cb = select(2, ...)
          return vim.schedule(function()
            cb({ ok = false, code = 1, records = {}, stderr = '',
              errors = { 'Usage: status [ -c changelist# ] [-a -e -d] [files...]\nInvalid option: -m.' } })
          end)
        end
      end
      return run(self, args, ...)
    end
    _G.scan = function()
      _G.out = nil
      local cv = require('perforated.views.client')
      require('perforated.changelists').status(ws, cv.reconcile_args(ws, { 'src' }), function(recs, err)
        local names = {}
        for _, r in ipairs(recs or {}) do
          names[#names + 1] = vim.fs.basename(r.clientFile or r.depotFile) .. ':' .. r.action
        end
        table.sort(names)
        _G.out = { names = names, err = err }
      end)
    end
  ]])
  local function scan()
    child.lua('_G.scan()')
    H.wait(child, '_G.out ~= nil', 15000)
    return child.lua_get('_G.out')
  end
  return child, root, scan
end

--- Rewrite a file, keeping its modification time (as `cp -p` does).
local function edit_keep_mtime(path, content)
  local st = assert(vim.uv.fs_stat(path))
  vim.uv.fs_chmod(path, tonumber('644', 8))
  H.write(path, content)
  vim.uv.fs_utime(path, st.mtime.sec + st.mtime.nsec / 1e9, st.mtime.sec + st.mtime.nsec / 1e9)
  vim.uv.fs_chmod(path, st.mode)
end

T['the scan hashes only files whose mtime moved (status -m)'] = function()
  local child, root, scan = scan_setup()
  edit_keep_mtime(root .. '/src/a.c', 'two\n')
  H.write(root .. '/src/new.c', 'x\n')
  local out = scan()
  -- The edit that kept its mtime isn't hashed: only the add is found.
  H.eq(out.names, { 'new.c:add' })
  H.eq(child.lua_get('_G.status_args[1]'), { 'status', '-m' })
  -- Once the mtime moves, the edit is found.
  local t = os.time() + 5
  vim.uv.fs_utime(root .. '/src/a.c', t, t)
  out = scan()
  child.stop()
  H.eq(out.names, { 'a.c:edit', 'new.c:add' })
end

T['reconcile.mtime = false hashes every file'] = function()
  local child, root, scan = scan_setup({ client_view = { reconcile = { mtime = false } } })
  edit_keep_mtime(root .. '/src/a.c', 'two\n')
  local out = scan()
  local args = child.lua_get('_G.status_args[1]')
  child.stop()
  H.eq(out.names, { 'a.c:edit' })
  H.eq(args, { 'status' })
end

T['a server without status -m: the scan asks without it, and remembers'] = function()
  local child, root, scan = scan_setup()
  child.lua('_G.reject_m = true')
  H.write(root .. '/src/new.c', 'x\n')
  local out = scan()
  H.eq(out, { names = { 'new.c:add' } })
  out = scan()
  local args = child.lua_get('_G.status_args')
  child.stop()
  H.eq(out, { names = { 'new.c:add' } })
  H.eq(args, { { 'status', '-m' }, { 'status' }, { 'status' } })
end

return T
