--- Gutter signs (one ranged extmark per hunk), hunk navigation, preview and reset.

local engine = require('perforated.diff.engine')

local M = {}

M.ns = vim.api.nvim_create_namespace('perforated.signs')
M.ns_stale = vim.api.nvim_create_namespace('perforated.stale')
M.ns_preview = vim.api.nvim_create_namespace('perforated.preview')

local HL = { add = 'PerforatedAdd', change = 'PerforatedChange', delete = 'PerforatedDelete' }

--- Render hunks as signs. One extmark per hunk: `end_row` spreads the sign over every line.
---@param buf integer
---@param hunks perforated.Hunk[]
function M.render(buf, hunks)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if #hunks == 0 then
    return
  end
  local cfg = require('perforated.config').get().signs
  local last = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local top, bottom = engine.range(h)
    top, bottom = math.min(top, last), math.min(bottom, last)
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, top - 1, 0, {
      end_row = bottom - 1,
      sign_text = cfg.text[h.type],
      sign_hl_group = HL[h.type],
      priority = cfg.priority,
    })
  end
end

--- Stale indicator (have < head) on line 1, below hunk signs in priority.
---@param buf integer
---@param stale boolean
function M.render_stale(buf, stale)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns_stale, 0, -1)
  if stale then
    local cfg = require('perforated.config').get().signs
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns_stale, 0, 0, {
      sign_text = cfg.text.stale,
      sign_hl_group = 'PerforatedStale',
      priority = math.max(cfg.priority - 1, 0),
    })
  end
end

---@param buf integer
---@return perforated.Hunk[]
local function hunks_of(buf)
  local st = require('perforated.buffer').get(buf)
  return st and st.hunks or {}
end

--- Hunk covering a line.
---@param buf integer?
---@param line integer? 1-based (default: cursor)
---@return perforated.Hunk?, integer? index
function M.hunk_at(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  for i, h in ipairs(hunks_of(buf)) do
    local top, bottom = engine.range(h)
    if line >= top and line <= bottom then
      return h, i
    end
  end
end

--- Jump to the next/previous hunk (wraps around; honours a count).
---@param forward boolean
---@param count integer?
function M.nav(forward, count)
  local buf = vim.api.nvim_get_current_buf()
  local hunks = hunks_of(buf)
  if #hunks == 0 then
    return require('perforated.ui.toast').notify('[perforated] no hunks', vim.log.levels.INFO)
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _ = 1, math.max(count or 1, 1) do
    local found
    if forward then
      for _, h in ipairs(hunks) do
        local top = engine.range(h)
        if top > line then
          found = top
          break
        end
      end
      found = found or engine.range(hunks[1])
    else
      for i = #hunks, 1, -1 do
        local top = engine.range(hunks[i])
        if top < line then
          found = top
          break
        end
      end
      found = found or engine.range(hunks[#hunks])
    end
    line, target = found, found
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd('normal! zv')
end

-- Tokens of a line for the word diff: runs of word characters (any non-ASCII byte counts, so
-- a multibyte character stays whole), runs of whitespace, single other characters.
---@param s string
---@return integer[][] {first, last} byte positions (1-based, inclusive)
local function tokens(s)
  local t, pos = {}, 1
  while pos <= #s do
    local _, e = s:find('^[%w_\128-\255]+', pos)
    if not e then
      _, e = s:find('^%s+', pos)
    end
    e = e or pos
    t[#t + 1] = { pos, e }
    pos = e + 1
  end
  return t
end

--- The changed parts of a line pair, word by word: byte ranges `{start, end}` (0-based, end
--- exclusive) in each. Nil when they have no word in common (the whole line is the change,
--- and the line colour already says so).
---@param a string old line
---@param b string new line
---@return integer[][]? old, integer[][]? new
function M._word_diff(a, b)
  local ta, tb = tokens(a), tokens(b)
  if #ta == 0 or #tb == 0 then
    return nil
  end
  local function text(s, t)
    local out = {}
    for i, r in ipairs(t) do
      out[i] = s:sub(r[1], r[2])
    end
    return table.concat(out, '\n') .. '\n'
  end
  local difffn = (vim.text and vim.text.diff) or vim.diff -- vim.diff is deprecated in 0.12+
  local hunks = difffn(text(a, ta), text(b, tb), { result_type = 'indices' }) --[[@as integer[][] ]]
  local ra, rb, changed = {}, {}, {}
  for _, h in ipairs(hunks) do
    if h[2] > 0 then
      ra[#ra + 1] = { ta[h[1]][1] - 1, ta[h[1] + h[2] - 1][2] }
      for k = h[1], h[1] + h[2] - 1 do
        changed[k] = true
      end
    end
    if h[4] > 0 then
      rb[#rb + 1] = { tb[h[3]][1] - 1, tb[h[3] + h[4] - 1][2] }
    end
  end
  -- Only whitespace in common: no word kept, so no point.
  for k, r in ipairs(ta) do
    if not changed[k] and a:sub(r[1], r[2]):find('%S') then
      return ra, rb
    end
  end
  return nil
end

--- Floating preview of the hunk under the cursor (old lines `-`, new lines `+`). In a change
--- hunk, old and new lines are paired in order and the words that changed get
--- `PerforatedPreviewText` (diff mode's `DiffText`). Syntax colouring follows `diff.syntax`.
function M.preview()
  local buf = vim.api.nvim_get_current_buf()
  local st = require('perforated.buffer').get(buf)
  local h = M.hunk_at(buf)
  if not st or not h or not st.base then
    return require('perforated.ui.toast').notify(
      '[perforated] no hunk under cursor',
      vim.log.levels.INFO
    )
  end
  local lines, hls = {}, {}
  for i = h.a_start, h.a_start + h.a_count - 1 do
    lines[#lines + 1] = '-' .. (st.base[i] or '')
    hls[#lines] = 'PerforatedPreviewDelete'
  end
  local cur = vim.api.nvim_buf_get_lines(buf, h.b_start - 1, h.b_start - 1 + h.b_count, false)
  for _, l in ipairs(cur) do
    lines[#lines + 1] = '+' .. l
    hls[#lines] = 'PerforatedPreviewAdd'
  end
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  -- The line colours as ranged highlights to the end of the line, not `line_hl_group`: that
  -- one is drawn over ranged highlights whatever their priority, hiding the changed words.
  for i, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(
      pbuf,
      M.ns_preview,
      i - 1,
      0,
      { end_row = i, end_col = 0, hl_group = hl, hl_eol = true, priority = 4096 }
    )
  end
  for i = 1, math.min(h.a_count, #cur) do
    local old_row, new_row = i - 1, h.a_count + i - 1
    local ra, rb = M._word_diff(lines[old_row + 1]:sub(2), lines[new_row + 1]:sub(2))
    for row, ranges in pairs({ [old_row] = ra, [new_row] = rb }) do
      for _, r in ipairs(ranges or {}) do
        vim.api.nvim_buf_set_extmark(pbuf, M.ns_preview, row, r[1] + 1, {
          end_col = r[2] + 1,
          hl_group = 'PerforatedPreviewText',
          priority = 5000, -- over the line colour
        })
      end
    end
  end
  if (require('perforated.config').get().diff or {}).syntax == true then
    vim.bo[pbuf].filetype = vim.bo[buf].filetype
  end
  vim.bo[pbuf].bufhidden = 'wipe'
  local width = 10
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = vim.api.nvim_open_win(pbuf, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(width + 1, math.floor(vim.o.columns * 0.8)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.5)),
    style = 'minimal',
    border = 'rounded',
    title = (' hunk %s '):format(h.type),
    focusable = true,
  })
  -- `<Esc>` closes it too (it doesn't move the cursor): a temporary mapping in the file's
  -- buffer, giving back a buffer-local `<Esc>` the user had. `q`/`<Esc>` in the preview itself.
  local saved = vim.fn.maparg('<Esc>', 'n', false, true)
  saved = saved.buffer == 1 and saved or nil
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, 'n', '<Esc>', { buffer = buf })
      if saved then
        vim.api.nvim_buf_call(buf, function()
          vim.fn.mapset('n', false, saved)
        end)
      end
    end
  end
  vim.keymap.set(
    'n',
    '<Esc>',
    close,
    { buffer = buf, nowait = true, desc = 'perforated: close preview' }
  )
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close, { buffer = pbuf, nowait = true })
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufLeave' }, {
    buffer = buf,
    once = true,
    callback = close,
  })
  vim.api.nvim_create_autocmd(
    'WinClosed',
    { pattern = tostring(win), once = true, callback = close }
  )
  return win
end

--- Restore the hunk under the cursor to the base text (undoable).
function M.reset()
  local buf = vim.api.nvim_get_current_buf()
  local st = require('perforated.buffer').get(buf)
  local h = M.hunk_at(buf)
  if not st or not h or not st.base then
    return require('perforated.ui.toast').notify(
      '[perforated] no hunk under cursor',
      vim.log.levels.INFO
    )
  end
  local old = {}
  for i = h.a_start, h.a_start + h.a_count - 1 do
    old[#old + 1] = st.base[i]
  end
  if h.type == 'delete' then
    vim.api.nvim_buf_set_lines(buf, h.b_start, h.b_start, false, old)
  else
    vim.api.nvim_buf_set_lines(buf, h.b_start - 1, h.b_start - 1 + h.b_count, false, old)
  end
  require('perforated.buffer').update(buf)
end

return M
