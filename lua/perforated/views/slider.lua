--- P4V-style slider for the time-lapse view: a two-line window above it with a tick per
--- revision, the handles (● the shown revision, ◆ the other end in diff / range mode) and
--- labels on a revision, changelist or date scale. Click on the track to jump.
---
---   ├──┼───┼──◆════════●───┼──┼─────┤
---   [diff #9 → #14]  #1          #14 · CL 4567 · alice · 2026-09-20          #30

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

---@param view table  time-lapse view
---@param n integer
---@return string
local function label(view, n)
  local r = view.tl.revs[n] or {}
  if view.scale == 'change' then
    return 'CL ' .. (r.change or '?')
  elseif view.scale == 'date' then
    local t = tonumber(r.time)
    return t and os.date('%Y-%m-%d', t) or '?'
  end
  return '#' .. n
end

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
  -- Byte offsets for highlights (the glyphs are multi-byte).
  local parts, bytes = { ' ' }, { [0] = 1 }
  for c = 0, width - 1 do
    parts[#parts + 1] = cells[c]
    bytes[c + 1] = bytes[c] + #cells[c]
  end
  local track = table.concat(parts)

  local r = view.tl.revs[b] or {}
  local t = tonumber(r.time)
  local mode = view.mode == 'diff' and ('[diff %s → %s]'):format(label(view, a), label(view, b))
    or view.mode == 'range' and ('[range %s..%s]'):format(label(view, a), label(view, b))
    or '[single]'
  local center = ('%s · CL %s · %s · %s'):format(
    '#' .. b,
    r.change or '?',
    r.user or '?',
    t and os.date('%Y-%m-%d', t) or ''
  )
  local o = order(view.tl)
  local left = ' ' .. mode .. '  ' .. label(view, o[1])
  local right = label(view, o[#o]) .. ' '
  local total = width + 2
  local gap = total - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
  local cw = vim.fn.strdisplaywidth(center)
  local labels
  if gap >= cw + 2 then
    local l = math.floor((gap - cw) / 2)
    labels = left .. (' '):rep(l) .. center .. (' '):rep(gap - cw - l) .. right
  else
    labels = left .. '  ' .. center
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { track, labels })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  local buf = self.buf
  local function hl(line, s, e, group)
    local text = line == 0 and track or labels
    vim.api.nvim_buf_set_extmark(buf, ns, line, s, {
      end_col = e < 0 and #text or math.min(e, #text),
      hl_group = group,
    })
  end
  hl(0, 0, -1, 'PerforatedSliderTrack')
  if a then
    hl(0, bytes[lo], bytes[hi + 1], 'PerforatedSliderRange')
    if pos[a] then
      hl(0, bytes[pos[a]], bytes[pos[a] + 1], 'PerforatedSliderHandleA')
    end
  end
  if pos[b] then
    hl(0, bytes[pos[b]], bytes[pos[b] + 1], 'PerforatedSliderHandle')
  end
  hl(1, 0, -1, 'PerforatedDim')
  local s = labels:find(center, 1, true)
  if s then
    hl(1, s - 1, s - 1 + #center, 'PerforatedTitle')
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
  vim.api.nvim_win_call(view.win, function()
    vim.cmd('aboveleft 2split')
  end)
  local win = vim.fn.win_getid(vim.fn.winnr('k'), vim.api.nvim_win_get_tabpage(view.win))
  win = (win ~= 0 and win ~= view.win) and win or vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    'perforated://slider/' .. (view.tl and view.tl.depotFile or '')
  )
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.cursorline, wo.wrap, wo.winfixheight, wo.list = false, false, true, false
  wo.winbar, wo.statusline = '', ' '
  vim.api.nvim_win_set_height(win, 2)
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
