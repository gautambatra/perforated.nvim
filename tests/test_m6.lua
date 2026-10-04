-- M6: timings, memory soak (real p4d unless noted).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

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
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_deep_extend('force', {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
    }, config or {}),
  })
  child.cmd('edit ' .. root .. '/a.txt')
  wait([[(require('perforated.buffer').get() or {}).status == 'clean']])
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

T['m6']['p4vc is gone: no :P4 p4vc, no revision graph action or <Plug> map'] = function()
  setup()
  H.eq(vim.tbl_contains(child.lua_get([[require('perforated.commands').names()]]), 'p4vc'), false)
  H.eq(child.fn.maparg('<Plug>(perforated-revgraph)', 'n'), '')
  H.eq(child.lua_get([[pcall(require, 'perforated.p4vc')]]), false)
  child.cmd('P4')
  wait(
    [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('b.txt', 1, true) ~= nil]]
  )
  local ids = child.lua_get([[(function()
    local v = require('perforated.views.client')._get(require('perforated').workspace().key)
    return vim.tbl_map(function(a) return a.id end, v.actions)
  end)()]])
  H.eq(vim.tbl_contains(ids, 'revgraph'), false)
  H.eq(vim.tbl_contains(ids, 'p4vc_timelapse'), false)
end

T['m6'][':P4 debug timings lists p4 commands and plugin timings'] = function()
  setup()
  child.cmd('P4')
  -- The refresh timing is recorded once every section has answered.
  wait([[(function()
    local v = vim.b.perforated_ws and require('perforated.views.client')._get(vim.b.perforated_ws)
    return v ~= nil and v.data ~= nil and not v.loading
  end)()]])
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
  -- Sizes of every table reachable from the plugin's modules (and their functions' upvalues).
  child.lua([[
    _G.sizes = function()
      local out, seen = {}, {}
      local function walk(t, path, depth)
        if seen[t] or depth > 4 then return end
        seen[t] = true
        local n = 0
        for k, v in pairs(t) do
          n = n + 1
          if type(v) == 'table' then walk(v, path .. '.' .. tostring(k), depth + 1) end
        end
        out[path] = n
      end
      for name, mod in pairs(package.loaded) do
        if name:match('^perforated') and type(mod) == 'table' then
          walk(mod, name, 0)
          for fk, f in pairs(mod) do
            if type(f) == 'function' then
              local i = 1
              while true do
                local un, uv = debug.getupvalue(f, i)
                if not un then break end
                if type(uv) == 'table' then walk(uv, name .. ':' .. fk .. '^' .. un, 1) end
                i = i + 1
              end
            end
          end
        end
      end
      return out
    end
    _G.sizes_before = _G.sizes()
  ]])
  local before = child.lua(gc)
  cycle(21, 1000)
  local after = child.lua(gc)
  local left = child.lua_get(
    [[{ vim.tbl_count(require('perforated.buffer').all()), vim.tbl_count(require('perforated.core.workspace').list()[1].fstat), #require('perforated.core.log').entries(), vim.tbl_count(require('perforated.core.workspace').list()[1].buffers or {}) }]]
  )
  H.eq(left[1], 0)
  H.eq(left[2], 0)
  -- A leak is a table that grows with every buffer: none may grow by more than 50 entries.
  local grown = child.lua_get([[(function()
    local now, out = _G.sizes(), {}
    for k, n in pairs(now) do
      if n - (_G.sizes_before[k] or 0) > 50 then out[#out + 1] = k .. ' +' .. (n - (_G.sizes_before[k] or 0)) end
    end
    table.sort(out)
    return out
  end)()]])
  H.eq(grown, {})
  -- Backstop for large leaks (GC and Neovim's own caches make small numbers noisy).
  local ours = (after - before) - neovim_growth
  if ours >= 400 then
    error(
      ('Lua memory grew %.0f KB over 980 open/close cycles (Neovim alone: %.0f KB)'):format(
        after - before,
        neovim_growth
      )
    )
  end
end

return T
