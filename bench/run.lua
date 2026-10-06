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
  local function measure(active, per_buffer)
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
    if not per_buffer then
      c.stop()
      return one - before
    end
    for i = 2, 101 do
      c.cmd(('edit %s/src/f%d.c'):format(root, i))
    end
    H.wait(c, 'false', 500)
    local many = c.lua(gc)
    c.stop()
    return one - before, (many - one) / 100
  end
  -- Each fresh Neovim's reading after opening a file varies by about ±13 KB, dormant and
  -- active alike: allocator state a full GC doesn't undo (waiting for in-flight p4 work to
  -- finish made no difference). So: 7 runs of each, interleaved, and a trimmed mean (drop
  -- the highest and lowest). Measured on 20+20 samples, that halves the spread of the result
  -- compared with min-of-3 − min-of-3 (sd 3.7 vs 7.6 KB), whose low dormant outliers caused
  -- the false failures. The minimum also read ~5 KB low; this doesn't.
  local function trimmed(xs)
    table.sort(xs)
    local sum = 0
    for i = 2, #xs - 1 do
      sum = sum + xs[i]
    end
    return sum / (#xs - 2)
  end
  -- The per-buffer figure (100 more files) is slow to take and has never been flaky: only in the
  -- first 3 runs, and as before, min − min.
  local d_one, d_per, a_one, a_per = {}, {}, {}, {}
  for run = 1, 7 do
    local per_buffer = run <= 3
    local one, per = measure(false, per_buffer)
    d_one[#d_one + 1], d_per[#d_per + 1] = one, per
    one, per = measure(true, per_buffer)
    a_one[#a_one + 1], a_per[#a_per + 1] = one, per
  end
  record('Lua memory: active workspace (code+state)', trimmed(a_one) - trimmed(d_one), 'KB', 250)
  local min = math.min
  record(
    'Lua memory: per attached buffer',
    math.max(min(unpack(a_per)) - min(unpack(d_per)), 0),
    'KB',
    2
  )
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

-- 6. Client view: rendering 5000 rows (50 CLs × 100 files) and the first paint of :P4.
do
  local c = H.child()
  local ms = c.lua([[
    local tree = require('perforated.ui.tree').new(vim.api.nvim_get_current_buf())
    vim.bo.buftype = 'nofile'
    require('perforated.hl').setup()
    local roots = {}
    for cl = 1, 50 do
      local files = {}
      for f = 1, 100 do
        files[f] = { id = ('f:%d:%d'):format(cl, f), kind = 'opened_file', item = {}, text = {
          { 'edit      ', 'PerforatedAction' }, { ('src/module%d/file%d.cpp'):format(cl, f), 'PerforatedPath' },
          { '  #3/#4', 'PerforatedRev' }, { '  stale', 'PerforatedStale' } } }
      end
      roots[cl] = { id = 'cl:' .. cl, kind = 'change', item = {}, children = files,
        text = { { 'CL ' .. cl, 'PerforatedChangelist' }, { '  some description', 'PerforatedPath' } } }
    end
    tree:set(roots) -- warm-up
    local samples = {}
    for _ = 1, 9 do
      local t0 = vim.uv.hrtime()
      tree:set(roots)
      samples[#samples + 1] = vim.uv.hrtime() - t0
    end
    table.sort(samples)
    return samples[1] / 1e6
  ]])
  record('client view: render 5000 rows', ms, 'ms', 15)
  c.stop()

  local root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(root .. '/a.c', 'x')
  -- First paint happens once per Neovim: best of 3 fresh instances.
  local paint = math.huge
  for _ = 1, 3 do
    local c2 = H.child({
      fake = {
        rules = {
          {
            match = '^info',
            records = { { clientName = 'ws1', clientRoot = root, userName = 'alice' } },
          },
          { match = '^set', stdout = 'P4CLIENT=ws1\n' },
          { match = '.', sleep = 0.3, records = {} },
        },
      },
      env = { P4CONFIG = '.p4config' },
      config = { p4 = H.fake_p4, poll = { interval = 0 }, startup_check = false },
    })
    c2.cmd('edit ' .. root .. '/a.c')
    H.wait(c2, [[(require('perforated.core.workspace').list()[1] or {}).settings ~= nil]], 10000)
    local one = c2.lua([[
      require('perforated.views.client') -- module load isn't part of the paint budget
      require('perforated.ui.tree'); require('perforated.ui.keys'); require('perforated.ui.footer')
      local ws = require('perforated').workspace()
      local t0 = vim.uv.hrtime()
      require('perforated.views.client').open(ws)
      return (vim.uv.hrtime() - t0) / 1e6
    ]])
    paint = math.min(paint, one)
    c2.stop()
  end
  record('client view: first paint (skeleton)', paint, 'ms', 16)
end

-- 7. Annotate: parsing 20k `annotate -c` records and rendering the 20k-line column.
-- Pure-Lua loops: best of 3 fresh Neovims (a CI runner occasionally gives one process a
-- much slower Lua; a real regression shows in all three).
do
  local code = [[
    local n = 20000
    local records = { { depotFile = '//depot/big.c', rev = '400', change = '9000' } }
    for i = 1, n do
      local cl = tostring(1000 + (i * 7919) % 400)
      records[#records + 1] = { data = 'line ' .. i .. '\n', lower = cl, upper = cl }
    end
    local history = require('perforated.history')
    local best_parse = math.huge
    local cls
    for _ = 1, 5 do
      local t0 = vim.uv.hrtime()
      local _, _, c2 = history._annotate_lines(records)
      best_parse = math.min(best_parse, vim.uv.hrtime() - t0)
      cls = c2
    end
    local meta = {}
    for c = 1000, 1399 do
      meta[c] = { change = c, user = 'user' .. c, time = tostring(1.7e9 + c * 1000), desc = 'd' }
    end
    local src = vim.api.nvim_get_current_buf()
    local src_win = vim.api.nvim_get_current_win()
    local lines = {}
    for i = 1, n do lines[i] = 'line ' .. i end
    vim.api.nvim_buf_set_lines(src, 0, -1, false, lines)
    vim.cmd('leftabove vnew')
    local a = require('perforated.views.annotate')
    a.define_age_groups()
    local view = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(),
      src_buf = src, src_win = src_win, local_file = false, ann = { cls = cls, meta = meta, depotFile = '//depot/big.c' } }
    local best_render = math.huge
    for _ = 1, 5 do
      local t0 = vim.uv.hrtime()
      a.render(view)
      best_render = math.min(best_render, vim.uv.hrtime() - t0)
    end
    return { best_parse / 1e6, best_render / 1e6 }
  ]]
  local parse_ms, render_ms = math.huge, math.huge
  for _ = 1, 3 do
    local c = H.child()
    local p, r = unpack(c.lua(code))
    parse_ms, render_ms = math.min(parse_ms, p), math.min(render_ms, r)
    c.stop()
  end
  record('annotate: parse 20k lines', parse_ms, 'ms', 20)
  record('annotate: render 20k lines', render_ms, 'ms', 25)
end

-- 8. Time-lapse: one step (rebuild the revision, set the buffer, decorations) for a 20k-line
--    file with 200 revisions. Revisions aren't cached in the measured runs.
do
  local code = [[
    local engine = require('perforated.timelapse')
    local view_mod = require('perforated.views.timelapse')
    require('perforated.hl').setup()
    local entries, seed = {}, 1
    local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
    for i = 1, 20000 do
      entries[#entries + 1] = { text = ('local x%d = compute(%d) -- typical source line'):format(i, i), lo = 1, hi = 200 }
    end
    -- ~50 changed lines per revision: an old version ending at r-1, a new one from r
    for r = 2, 200 do
      for _ = 1, 50 do
        local at = 1 + rnd(#entries)
        local e = entries[at]
        if e.lo < r and e.hi == 200 then
          e.hi = r - 1
          table.insert(entries, at + 1, { text = e.text .. ' -- r' .. r, lo = r, hi = 200 })
        end
      end
    end
    local revs = {}
    for r = 1, 200 do revs[r] = { rev = tostring(r), change = tostring(1000 + r), user = 'u', time = '0', desc = 'd' } end
    local tl = { depotFile = '//depot/big.c', revs = revs, first = 1, last = 200, head = 200, entries = entries, cache = {} }
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = 'nofile'
    local view = { tl = tl, buf = buf, win = vim.api.nvim_get_current_win(), actions = {},
      tree = { node_at = function() return nil end } }
    view_mod.show(view, 200)
    local samples = {}
    for i = 1, 9 do
      tl.cache = {}
      local t0 = vim.uv.hrtime()
      view_mod.show(view, 200 - i)
      samples[#samples + 1] = vim.uv.hrtime() - t0
    end
    table.sort(samples)
    -- Breakdown (printed, no budget): where a step's time goes.
    local function best(f)
      local b = math.huge
      for _ = 1, 5 do
        local t = vim.uv.hrtime()
        f()
        b = math.min(b, vim.uv.hrtime() - t)
      end
      return b / 1e6
    end
    local edits
    local t_tr = best(function() edits = engine.transition(tl, 190, 189, 100) end)
    local t_ed = best(function()
      vim.bo[buf].modifiable = true
      for _, e in ipairs(edits) do
        vim.api.nvim_buf_set_lines(buf, e.start, e.start + e.del, false, e.ins)
      end
      local back = engine.transition(tl, 189, 190, 1)
      for _, e in ipairs(back) do
        vim.api.nvim_buf_set_lines(buf, e.start, e.start + e.del, false, e.ins)
      end
    end) / 2
    view.n, view.changes = 190, nil
    local t_dec = best(function() view_mod.decorate(view) end)
    local t_wb = best(function() vim.wo[view.win].winbar = ' #190/#200 · CL 1190 · u · date' end)
    return { samples[1] / 1e6, ('transition %.2f · edits %.2f (%d) · decorate %.2f · winbar %.2f ms'):format(t_tr, t_ed, #edits, t_dec, t_wb) }
  ]]
  local ms = { math.huge, '' }
  for _ = 1, 3 do
    local c = H.child()
    local one = c.lua(code)
    if one[1] < ms[1] then
      ms = one
    end
    c.stop()
  end
  record('time-lapse: step, 20k lines × 200 revs', ms[1], 'ms', 5)
  print('  time-lapse step breakdown: ' .. ms[2])
end

-- 9. Diff look: (re)building the highlight namespaces, done when a diff opens and on
--    :colorscheme. ~1300 groups, as in a config with a full colorscheme and many plugins.
do
  local c = H.child()
  local ms = c.lua([[
    for i = 1, 900 do
      vim.api.nvim_set_hl(0, ('BenchGroup%d'):format(i), { fg = '#123456' })
    end
    local look = require('perforated.diff.look')
    local worst = 0 -- the slower of the two looks, each its best of 5
    for _, colors in ipairs({ 'colorscheme', 'perforated' }) do
      require('perforated.config').set({ diff = { colors = colors, syntax = false } })
      look.build()
      local best = math.huge
      for _ = 1, 5 do
        local t = vim.uv.hrtime()
        look.build()
        best = math.min(best, (vim.uv.hrtime() - t) / 1e6)
      end
      worst = math.max(worst, best)
    end
    return { worst, vim.tbl_count(vim.api.nvim_get_hl(0, {})) }
  ]])
  c.stop()
  record(('diff look: build (%d groups)'):format(ms[2]), ms[1], 'ms', 10)
end

-- 10. The plugin's own picker: opening a 500-item list (with preview) — below one frame — and
--     the slowest keystroke while typing a filter into 5000 items that all match the first
--     word (the worst case: nothing narrows until the second). Neovim's matcher (C) alone takes
--     7–10 ms there; real lists narrow sooner, and the debounce filters once per burst.
do
  local c = H.child()
  local ms = c.lua([[
    require('perforated.config').set({ picker = 'perforated' })
    local list = require('perforated.picker.list')
    local words = { 'Fix', 'parser', 'crash', 'lexer', 'tests', 'docs', 'cache', 'login' }
    local function items(n)
      local out = {}
      for i = 1, n do
        out[i] = ('#%-4d %-8d alice %s %s %s'):format(i, 100000 + i, words[i % 8 + 1], words[(i * 3) % 8 + 1], words[(i * 5) % 8 + 1])
      end
      return out
    end
    local function open(n)
      return list.open({
        title = 'Bench', items = items(n),
        format = function(s) return s end,
        preview = function(s) return { s } end,
        on_choice = function() end,
      }, function() end)
    end
    local t_open = math.huge
    for _ = 1, 5 do
      local t = vim.uv.hrtime()
      local p = open(500)
      vim.cmd.redraw()
      t_open = math.min(t_open, (vim.uv.hrtime() - t) / 1e6)
      p.close(nil)
    end
    -- Typing a query one character at a time (each keystroke narrows the previous matches):
    -- the slowest keystroke, best of 3 fresh pickers.
    local worst = math.huge
    for _ = 1, 3 do
      local p = open(5000)
      local run_worst = 0
      local q = 'alice parser'
      for k = 1, #q do
        p.query = q:sub(1, k)
        local t = vim.uv.hrtime()
        p.apply_filter()
        vim.cmd.redraw()
        run_worst = math.max(run_worst, (vim.uv.hrtime() - t) / 1e6)
      end
      p.close(nil)
      worst = math.min(worst, run_worst)
    end
    return { t_open, worst }
  ]])
  c.stop()
  record('picker: open 500 items (+preview)', ms[1], 'ms', 16)
  record('picker: typing a filter, 5000 items', ms[2], 'ms', 25)
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
