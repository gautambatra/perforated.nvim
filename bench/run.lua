-- Performance budgets (docs/plan.md §2). `make bench` exits non-zero when a budget is exceeded.
-- Timing metrics use the best of several runs: the budget is about the plugin's own cost, and
-- the minimum filters out scheduler noise from whatever else the machine (or CI runner) is doing.
local H = require('tests.helpers')

local results = {}

local function record(name, value, unit, budget)
  results[#results + 1] =
    { name = name, value = value, unit = unit, budget = budget, ok = value <= budget }
end

-- 1. Startup cost of plugin/perforated.lua (from --startuptime; best of 9 runs).
do
  local samples = {}
  for _ = 1, 9 do
    local log = H.tmp() .. '/startup.log'
    vim
      .system({
        'nvim',
        '--headless',
        '--clean',
        '-u',
        H.root .. '/tests/minimal_init.lua',
        '--startuptime',
        log,
        '-c',
        'qa!',
      }, { text = true })
      :wait()
    for line in io.lines(log) do
      -- clock  self+sourced  self:  sourcing <file>
      local self_ms = line:match('^%S+%s+%S+%s+(%S+): sourcing .*plugin/perforated%.lua')
      if self_ms then
        samples[#samples + 1] = tonumber(self_ms)
      end
    end
  end
  table.sort(samples)
  record('startup: plugin/perforated.lua', samples[1] or math.huge, 'ms', 0.5)
end

-- 2. Dormant cost: opening files outside any workspace (per buffer, after first).
local child = H.child({ fake = { rules = {} }, env = { P4CONFIG = '.p4config' } })
do
  local dir = H.tmp()
  for i = 1, 200 do
    H.write(('%s/d%d/f%d.txt'):format(dir, i % 20, i), 'x')
  end
  local ms = child.lua(
    [[
    local dir = ...
    local gate = require('perforated.gate')
    local t0 = vim.uv.hrtime()
    for i = 1, 200 do
      gate.lookup(('%s/d%d'):format(dir, i % 20))
    end
    return (vim.uv.hrtime() - t0) / 1e6 / 200
  ]],
    { dir }
  )
  record('gate lookup (dormant dir, avg)', ms, 'ms', 0.3)
  H.eq(#H.calls(child.fake.log), 0)
end
child.stop()

-- 3. Lua memory attributable to the plugin: (active − dormant) for the first workspace file
--    (code + workspace state) and per additional attached buffer. Opening files also loads
--    Neovim's own filetype Lua, which the dormant run cancels out.
do
  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  for i = 1, 101 do
    H.write(('%s/src/f%d.c'):format(root, i), 'x')
  end
  local gc = 'collectgarbage(); collectgarbage(); return collectgarbage("count")'
  local function measure(active)
    local c = H.child({
      fake = {
        rules = {
          {
            match = '^info',
            records = {
              {
                clientName = 'ws1',
                clientRoot = root,
                userName = 'alice',
                caseHandling = 'sensitive',
              },
            },
          },
          { match = '^set', stdout = 'P4CLIENT=ws1\n' },
        },
      },
      env = { P4CONFIG = active and '.p4config' or '.p4config-none' },
    })
    local before = c.lua(gc)
    c.cmd(('edit %s/src/f1.c'):format(root))
    if active then
      H.wait(c, [[(require('perforated.core.workspace').list()[1] or {}).settings ~= nil]], 10000)
    end
    H.wait(c, 'false', 300)
    local one = c.lua(gc)
    for i = 2, 101 do
      c.cmd(('edit %s/src/f%d.c'):format(root, i))
    end
    H.wait(c, 'false', 500)
    local many = c.lua(gc)
    c.stop()
    return one - before, (many - one) / 100
  end
  local d_one, d_per = measure(false)
  local a_one, a_per = measure(true)
  record('Lua memory: active workspace (code+state)', a_one - d_one, 'KB', 250)
  record('Lua memory: per attached buffer', math.max(a_per - d_per, 0), 'KB', 2)
end

-- 4. Sign refresh for a 10k-line file with ~100 hunks: main-thread cost only (read lines,
--    queue the worker-thread diff, render the result).
do
  local c = H.child()
  local ms = c.lua([[
    local engine = require('perforated.diff.engine')
    local signs = require('perforated.signs')
    require('perforated.hl').setup()
    local base, cur = {}, {}
    for i = 1, 10000 do
      base[i] = ('local x%d = compute(%d) -- some typical source line'):format(i, i)
      cur[i] = (i % 100 == 0) and ('changed ' .. i) or base[i]
    end
    local base_text = engine.join(base)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur)
    local runs, samples = 21, {}
    for _ = 1, runs do
      local t0 = vim.uv.hrtime()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local done
      engine.hunks_async(base_text, lines, function(h) done = h end)
      local t1 = vim.uv.hrtime()
      vim.wait(5000, function() return done ~= nil end, 1)
      local t2 = vim.uv.hrtime()
      signs.render(buf, done)
      samples[#samples + 1] = (t1 - t0) + (vim.uv.hrtime() - t2)
    end
    table.sort(samples)
    return samples[1] / 1e6 -- best run
  ]])
  record('sign refresh: 10k lines, 100 hunks (UI)', ms, 'ms', 5)
  c.stop()
end

-- 5. Synchronous cost of opening a workspace file: the gate lookup plus activation/attach
--    (p4 itself is async). Filetype detection etc. are Neovim's cost, not ours.
do
  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  for i = 1, 60 do
    H.write(('%s/d%d/f%d.c'):format(root, i % 6, i), 'x')
  end
  local c = H.child({
    fake = { rules = { { match = '.', sleep = 0.2, records = {} } } },
    env = { P4CONFIG = '.p4config' },
  })
  c.cmd(('edit %s/d1/f1.c'):format(root)) -- warm-up: loads modules once
  local ms = c.lua(
    [[
    local root = ...
    local gate = require('perforated.gate')
    local act = require('perforated.core.activation')
    local samples = {}
    for i = 2, 60 do
      local name = ('%s/d%d/f%d.c'):format(root, i % 6, i)
      local buf = vim.fn.bufadd(name)
      vim.fn.bufload(buf)
      local t0 = vim.uv.hrtime()
      act.attach(buf, name, gate.lookup(name:match('^(.*)/')))
      samples[#samples + 1] = vim.uv.hrtime() - t0
    end
    table.sort(samples)
    return samples[1] / 1e6 -- best
  ]],
    { root }
  )
  record('attach: gate + activation (sync part)', ms, 'ms', 0.3)
  c.stop()
end

-- Report.
local failed = false
print(('%-40s %10s %10s'):format('metric', 'value', 'budget'))
for _, r in ipairs(results) do
  print(
    ('%-40s %8.3f%s %8.3f%s %s'):format(
      r.name,
      r.value,
      r.unit,
      r.budget,
      r.unit,
      r.ok and 'ok' or 'OVER BUDGET'
    )
  )
  failed = failed or not r.ok
end
vim.cmd(failed and 'cquit 1' or 'qall!')
