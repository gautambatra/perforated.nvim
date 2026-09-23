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
    return vim.notify('[perforated] no hunks', vim.log.levels.INFO)
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

--- Floating preview of the hunk under the cursor (old lines `-`, new lines `+`).
function M.preview()
  local buf = vim.api.nvim_get_current_buf()
  local st = require('perforated.buffer').get(buf)
  local h = M.hunk_at(buf)
  if not st or not h or not st.base then
    return vim.notify('[perforated] no hunk under cursor', vim.log.levels.INFO)
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
  for i, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(pbuf, M.ns_preview, i - 1, 0, { line_hl_group = hl })
  end
  vim.bo[pbuf].filetype = vim.bo[buf].filetype
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
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufLeave' }, {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  return win
end

--- Restore the hunk under the cursor to the base text (undoable).
function M.reset()
  local buf = vim.api.nvim_get_current_buf()
  local st = require('perforated.buffer').get(buf)
  local h = M.hunk_at(buf)
  if not st or not h or not st.base then
    return vim.notify('[perforated] no hunk under cursor', vim.log.levels.INFO)
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
