--- P4V-style slider for the time-lapse view: a two-line window above it with a tick per
--- revision, the handles — ● the selected revision (shown in the buffer), ◆ the comparison
--- base in diff / range mode — and labels (changelists by default, revisions with `S`): the
--- first, last, ● and ◆ always, others where they fit. Click on the track to jump.
---
---   ├──┼───┼──◆════════●───┼──┼─────┤
---   1201   1244  1250      1302       1377

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.slider')

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

--- Revisions that exist, oldest first.
local function order(tl)
  if not tl.order then
    local o = {}
    for n in pairs(tl.revs) do
      o[#o + 1] = n
    end
    table.sort(o)
    tl.order = o
  end
  return tl.order
end

--- A tick's label: the changelist (default) or the revision.
---@param view table  time-lapse view
---@param n integer
---@return string
local function label(view, n)
  if view.scale == 'rev' then
    return '#' .. n
  end
  return tostring((view.tl.revs[n] or {}).change or '?')
end
M.label = label

---@class perforated.Slider
---@field view table
---@field win integer
---@field buf integer
local Slider = {}
Slider.__index = Slider

--- Column (0-based, in cells) of each revision on the track.
function Slider:positions(width)
  local o = order(self.view.tl)
  local pos, count = {}, #o
  for i, n in ipairs(o) do
    pos[n] = count == 1 and 0 or math.floor((i - 1) * (width - 1) / (count - 1))
  end
  return pos
end

function Slider:render()
  local view = self.view
  if not (vim.api.nvim_win_is_valid(self.win) and view.tl and view.n) then
    return
  end
  local width = math.max(10, vim.api.nvim_win_get_width(self.win) - 2)
  local pos = self:positions(width)
  local b, a = view.n, (view.mode ~= 'single') and view.a or nil

  -- Line 1: the track.
  local cells = {}
  for c = 0, width - 1 do
    cells[c] = '─'
  end
  for _, c in pairs(pos) do
    cells[c] = '┼'
  end
  cells[0], cells[width - 1] = '├', '┤'
  local lo, hi = a and math.min(pos[a] or 0, pos[b] or 0), a and math.max(pos[a] or 0, pos[b] or 0)
  if a then
    for c = lo + 1, hi - 1 do
      if cells[c] == '─' then
        cells[c] = '═'
      end
    end
  end
  if a and pos[a] then
    cells[pos[a]] = '◆'
  end
  if pos[b] then
    cells[pos[b]] = '●'
  end
  local parts, bytes = { ' ' }, { [0] = 1 }
  for c = 0, width - 1 do
    parts[#parts + 1] = cells[c]
    bytes[c + 1] = bytes[c] + #cells[c]
  end
  local track = table.concat(parts)

  -- Line 2: labels under their ticks — the selected (●), ◆, first and last always; others
  -- spread out (by bisection) wherever they fit without crowding.
  local line = {}
  for c = 0, width + 1 do
    line[c] = ' '
  end
  local taken = {} -- occupied [s, e] cell ranges (with a one-cell gap)
  local placed = {} -- rev → { s, e }
  local function place(n, force)
    if not pos[n] or placed[n] then
      return
    end
    local text = label(view, n)
    local s0 = math.max(0, math.min(width + 2 - #text, pos[n] + 1 - math.floor(#text / 2)))
    local e0 = s0 + #text - 1
    for _, r in ipairs(taken) do
      if s0 <= r[2] + 1 and e0 >= r[1] - 1 then
        if not force then
          return
        end
      end
    end
    for i = 1, #text do
      line[s0 + i - 1] = text:sub(i, i)
    end
    taken[#taken + 1] = { s0, e0 }
    placed[n] = { s0, e0 }
  end
  local o = order(view.tl)
  place(b, true)
  if a then
    place(a, true)
  end
  place(o[1])
  place(o[#o])
  local queue = { { 1, #o } }
  local qi = 1
  while queue[qi] do
    local r = queue[qi]
    qi = qi + 1
    if r[2] - r[1] > 1 then
      local mid = math.floor((r[1] + r[2]) / 2)
      place(o[mid])
      queue[#queue + 1] = { r[1], mid }
      queue[#queue + 1] = { mid, r[2] }
    end
  end
  local labels = table.concat(line, '', 0, width + 1)

  local mode = view.mode == 'diff'
      and ('incremental diff ◆ %s → ● %s'):format(label(view, a), label(view, b))
    or view.mode == 'range' and ('range: changes since ◆ %s'):format(label(view, a))
    or 'single'
  vim.wo[self.win].winbar = ('%%#PerforatedTitle# Time-lapse%%#PerforatedDim#  %s  ·  %s  ·  labels: %s (S)'):format(
    (view.tl.depotFile:gsub('%%', '%%%%')),
    mode,
    view.scale == 'rev' and 'revisions' or 'changelists'
  )
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { track, labels })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  local buf = self.buf
  local function hl(row, s, e, group)
    local text = row == 0 and track or labels
    vim.api.nvim_buf_set_extmark(buf, ns, row, s, {
      end_col = e < 0 and #text or math.min(e, #text),
      hl_group = group,
    })
  end
  hl(0, 0, -1, 'PerforatedSliderTrack')
  hl(1, 0, -1, 'PerforatedDim')
  if a then
    hl(0, bytes[lo], bytes[hi + 1], 'PerforatedSliderRange')
    if pos[a] then
      hl(0, bytes[pos[a]], bytes[pos[a] + 1], 'PerforatedSliderHandleA')
    end
    if placed[a] then
      hl(1, placed[a][1], placed[a][2] + 1, 'PerforatedSliderHandleA')
    end
  end
  if pos[b] then
    hl(0, bytes[pos[b]], bytes[pos[b] + 1], 'PerforatedSliderHandle')
  end
  if placed[b] then
    hl(1, placed[b][1], placed[b][2] + 1, 'PerforatedSliderHandle')
  end
end

--- The revision nearest to a screen column of the slider window.
---@param col integer  1-based window column
---@return integer?
function Slider:rev_at(col)
  local width = math.max(10, vim.api.nvim_win_get_width(self.win) - 2)
  local pos = self:positions(width)
  local c = col - 2 -- one-cell margin, 0-based
  local best, dist
  for n, p in pairs(pos) do
    local d = math.abs(p - c)
    if not dist or d < dist or (d == dist and n > best) then
      best, dist = n, d
    end
  end
  return best
end

function Slider:close()
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
end

--- Open the slider above the time-lapse window.
---@param view table
---@param on_click fun(rev: integer)
---@return perforated.Slider
function M.attach(view, on_click)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  -- Three lines: a title winbar (always ours: a global 'winbar' would otherwise take one of
  -- the slider's lines), the track and the labels.
  local win = vim.api.nvim_open_win(buf, false, { split = 'above', win = view.win, height = 3 })
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    'perforated://slider/' .. (view.tl and view.tl.depotFile or '')
  )
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.cursorline, wo.wrap, wo.winfixheight, wo.list = false, false, true, false
  wo.statusline = ' '
  vim.api.nvim_win_set_height(win, 3)
  local self = setmetatable({ view = view, win = win, buf = buf }, Slider)
  -- Clicks jump; otherwise focus goes straight back to the time-lapse window.
  vim.keymap.set('n', '<LeftMouse>', function()
    local mp = vim.fn.getmousepos()
    if mp.winid == win then
      local rev = self:rev_at(mp.wincol)
      vim.api.nvim_set_current_win(view.win)
      if rev then
        on_click(rev)
      end
    end
  end, { buffer = buf })
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_get_current_win() == win then
          vim.api.nvim_set_current_win(view.win)
        end
      end)
    end,
  })
  local group = vim.api.nvim_create_augroup('perforated.slider.' .. win, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return true -- delete the autocmd
      end
      self:render()
    end,
  })
  vim.api.nvim_set_current_win(view.win)
  self:render()
  return self
end

M.first_line = first_line

return M
