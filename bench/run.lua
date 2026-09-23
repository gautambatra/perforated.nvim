-- Performance budgets (docs/plan.md §2). `make bench` exits non-zero when a budget is exceeded.
local H = require('tests.helpers')

local results = {}

local function record(name, value, unit, budget)
  results[#results + 1] =
    { name = name, value = value, unit = unit, budget = budget, ok = value <= budget }
end

-- 1. Startup cost of plugin/perforated.lua (from --startuptime; median of 7 runs).
do
  local samples = {}
  for _ = 1, 7 do
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
  record('startup: plugin/perforated.lua', samples[math.ceil(#samples / 2)] or math.huge, 'ms', 0.5)
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
    local gate = package.loaded['perforated.gate']
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

-- 3. Lua memory attributable to the plugin: an active workspace with 50 buffers, minus the
--    same session with the plugin dormant (opening buffers loads Neovim's own filetype Lua).
do
  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  for i = 1, 50 do
    H.write(('%s/src/f%d.c'):format(root, i), 'x')
  end
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
    local before = c.lua('collectgarbage(); collectgarbage(); return collectgarbage("count")')
    for i = 1, 50 do
      c.cmd(('edit %s/src/f%d.c'):format(root, i))
    end
    if active then
      H.wait(c, [[(require('perforated.core.workspace').list()[1] or {}).settings ~= nil]], 10000)
    else
      H.wait(c, 'false', 300)
    end
    local after = c.lua('collectgarbage(); collectgarbage(); return collectgarbage("count")')
    c.stop()
    return after - before
  end
  local dormant, active = measure(false), measure(true)
  record('Lua memory: workspace + 50 buffers', active - dormant, 'KB', 200)
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
