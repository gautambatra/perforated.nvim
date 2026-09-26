--- `:P4 debug timings`: where the time goes — p4 calls per command (from the command log) and
--- the plugin's own UI work (client view refresh and render, annotate, time-lapse steps, …).

local M = {}

--- The p4 command in an argv (after the binary and global options).
---@param argv string[]
---@return string
local function command_of(argv)
  local with_value =
    { ['-x'] = true, ['-c'] = true, ['-u'] = true, ['-p'] = true, ['-C'] = true, ['-d'] = true }
  local i = 2
  while argv[i] do
    local a = argv[i]
    if with_value[a] then
      i = i + 2
    elseif a:sub(1, 1) == '-' then
      i = i + 1
    else
      return a
    end
  end
  return '?'
end
M._command_of = command_of

--- Report lines.
---@return string[]
function M.lines()
  local out = {}
  local entries = require('perforated.core.log').entries()
  local by = {}
  for _, e in ipairs(entries) do
    local c = command_of(e.argv or {})
    local t = by[c] or { n = 0, total = 0, max = 0, errors = 0 }
    by[c] = t
    t.n, t.total = t.n + 1, t.total + (e.ms or 0)
    t.max = math.max(t.max, e.ms or 0)
    if e.err then
      t.errors = t.errors + 1
    end
  end
  local cmds = vim.tbl_keys(by)
  table.sort(cmds, function(a, b)
    return by[a].total > by[b].total
  end)
  out[#out + 1] = ('p4 commands (last %d calls)'):format(#entries)
  out[#out + 1] = ('  %-14s %6s %10s %9s %9s %7s'):format(
    'command',
    'calls',
    'total ms',
    'avg ms',
    'max ms',
    'errors'
  )
  for _, c in ipairs(cmds) do
    local t = by[c]
    out[#out + 1] = ('  %-14s %6d %10.0f %9.1f %9.1f %7d'):format(
      c,
      t.n,
      t.total,
      t.total / t.n,
      t.max,
      t.errors
    )
  end
  local ui = require('perforated.core.debug')._timings
  local names = vim.tbl_keys(ui)
  table.sort(names)
  out[#out + 1] = ''
  out[#out + 1] = 'plugin (this session)'
  out[#out + 1] = ('  %-30s %6s %9s %9s %9s'):format(
    'operation',
    'count',
    'avg ms',
    'max ms',
    'last ms'
  )
  for _, name in ipairs(names) do
    local t = ui[name]
    out[#out + 1] = ('  %-30s %6d %9.1f %9.1f %9.1f'):format(
      name,
      t.n,
      t.total / t.n,
      t.max,
      t.last
    )
  end
  if #names == 0 then
    out[#out + 1] = '  (nothing measured yet)'
  end
  out[#out + 1] = ''
  out[#out + 1] = ('Lua memory: %.0f KB'):format(collectgarbage('count'))
  return out
end

--- Show the report in a float (`q` / `<Esc>` close, `gr` refreshes).
function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local function fill()
    local lines = M.lines()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    return lines
  end
  local lines = fill()
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' perforated timings ',
    footer = ' gr refresh · q close ',
    footer_pos = 'right',
  })
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set('n', 'gr', fill, { buffer = buf, nowait = true })
  return buf, win
end

return M
