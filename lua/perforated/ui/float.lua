--- Small floating UI helpers: the single-key modal menu (check-out / add prompts, `.` menus).
--- Items are chosen by key or by a left click; a click outside the menu cancels it (and a
--- right-click there is passed on, so it can open another menu).

local M = {}

M.ns = vim.api.nvim_create_namespace('perforated.float')

--- Mouse keys other than a left click, which the menu ignores (keytrans names, without <>).
local MOUSE = {}
for _, b in ipairs({ 'Left', 'Right', 'Middle', 'X1', 'X2' }) do
  for _, ev in ipairs({ 'Mouse', 'Drag', 'Release' }) do
    MOUSE[b .. ev] = true
  end
end
for _, d in ipairs({ 'Up', 'Down', 'Left', 'Right' }) do
  MOUSE['ScrollWheel' .. d] = true
end
MOUSE.MouseMove = true

---@class perforated.MenuItem
---@field key string    keytrans() form, e.g. '<CR>', 'c', 'S'
---@field label string
---@field value any
---@field aliases string[]?  more keys that choose it (not shown)
---@field hint string?       shown in a right-hand column, aligned (e.g. `Ctrl+R`)
---@field separator boolean?  a horizontal rule instead of a choice (no key, label or value)

---@class perforated.MenuOpts
---@field title string
---@field header string[]?     lines shown above the choices
---@field items perforated.MenuItem[]
---@field grace integer?        ms after opening during which keys count as typing, not choices
---@field relative 'cursor'|'editor'|nil
---@field header_hl string|false|nil  highlight of the header lines (default PerforatedDim)

--- Show a single-key menu and wait for a choice (processes events meanwhile, so async work keeps
--- running). Keys pressed during the grace period are returned for replay: they were almost
--- certainly the rest of what the user was typing when the menu popped up.
---@param opts perforated.MenuOpts
---@return perforated.MenuItem? choice  nil when cancelled (<Esc>, q, <C-c>)
---@return string replay  raw keys to feed back
function M.menu(opts)
  local lines, key_hls = {}, {}
  for _, h in ipairs(opts.header or {}) do
    lines[#lines + 1] = ' ' .. h
  end
  if #lines > 0 then
    lines[#lines + 1] = ''
  end
  local seps, hint_hls, by_line = {}, {}, {}
  local label_w = 0
  for _, it in ipairs(opts.items) do
    if it.hint then
      label_w = math.max(label_w, vim.fn.strdisplaywidth(it.label))
    end
  end
  for _, it in ipairs(opts.items) do
    if it.separator then
      lines[#lines + 1] = ''
      seps[#seps + 1] = #lines
    else
      local key = it.key
      local line = ('  %-6s %s'):format(key, it.label)
      if it.hint then
        line = line .. (' '):rep(label_w - vim.fn.strdisplaywidth(it.label) + 4)
        hint_hls[#lines + 1] = { #line, #line + #it.hint }
        line = line .. it.hint
      end
      lines[#lines + 1] = line
      key_hls[#lines] = #key
      by_line[#lines] = it
    end
  end
  local width = vim.fn.strdisplaywidth(opts.title) + 4
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)
  for _, i in ipairs(seps) do
    lines[i] = ('─'):rep(width)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, n in pairs(key_hls) do
    vim.api.nvim_buf_set_extmark(
      buf,
      M.ns,
      i - 1,
      2,
      { end_col = 2 + n, hl_group = 'PerforatedKey' }
    )
  end
  for _, i in ipairs(seps) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, 0, { line_hl_group = 'PerforatedFloatBorder' })
  end
  for i, r in pairs(hint_hls) do
    vim.api.nvim_buf_set_extmark(
      buf,
      M.ns,
      i - 1,
      r[1],
      { end_col = r[2], hl_group = 'PerforatedKey' }
    )
  end
  local header_hl = opts.header_hl == nil and 'PerforatedDim' or opts.header_hl
  for i = 1, header_hl and #(opts.header or {}) or 0 do
    vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, 0, { line_hl_group = header_hl })
  end

  local relative = opts.relative or 'cursor'
  local win_opts = {
    relative = relative,
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. opts.title .. ' ',
    title_pos = 'left',
    focusable = false,
    noautocmd = true,
    zindex = 200,
  }
  if relative == 'cursor' then
    local row = vim.fn.winline()
    local below = vim.api.nvim_win_get_height(0) - row >= #lines + 2
    win_opts.row = below and 1 or -(#lines + 2)
    win_opts.col = 0
  else
    win_opts.row = math.floor((vim.o.lines - #lines) / 2) - 1
    win_opts.col = math.floor((vim.o.columns - width) / 2)
  end
  local win = vim.api.nvim_open_win(buf, false, win_opts)
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  vim.cmd.redraw()

  M.active = opts.title -- observable while waiting (tests, statusline)
  local by_key = {}
  for _, it in ipairs(opts.items) do
    if it.key then
      by_key[it.key] = it
    end
    for _, k in ipairs(it.aliases or {}) do
      by_key[k] = by_key[k] or it
    end
  end
  -- Multi-key choices (`gY`, `g@`): keys typed so far that start a longer key wait for the rest.
  local function is_prefix(typed)
    for k in pairs(by_key) do
      if #k > #typed and k:sub(1, #typed) == typed then
        return true
      end
    end
    return false
  end
  local grace = opts.grace or 0
  local opened = vim.uv.now()
  local replay = {}
  local choice
  local typed = ''
  while true do
    local ok, raw = pcall(vim.fn.getcharstr)
    if not ok then
      break -- <C-c>
    end
    local key = vim.fn.keytrans(raw)
    if vim.uv.now() - opened < grace then
      replay[#replay + 1] = raw
    elseif key == '<LeftMouse>' or key == '<RightMouse>' then
      -- Hit-tested against the menu's own screen rectangle (inside its 1-cell border):
      -- getmousepos() only knows focusable floats, and this one must never take focus.
      local pos = vim.fn.getmousepos()
      local at = vim.api.nvim_win_get_position(win)
      local line = pos.screenrow - at[1] - 1
      local col = pos.screencol - at[2] - 1
      local inside = line >= 1 and line <= #lines and col >= 1 and col <= width
      if not inside then
        -- Outside: cancel. A right-click is handed back, so the line it hit gets its own menu.
        if key == '<RightMouse>' then
          vim.api.nvim_feedkeys(raw, 'mt', false)
        end
        break
      end
      -- Inside: a left click chooses the item under it; a right click does nothing.
      if key == '<LeftMouse>' and by_line[line] then
        choice = by_line[line]
        break
      end
    elseif key == '<Esc>' or key == '<C-C>' or (key == 'q' and typed == '' and not by_key.q) then
      break
    elseif not MOUSE[key:match('(%w+)>$') or ''] then
      -- (Other mouse events — release, drag, wheel, right click — do nothing.)
      typed = typed .. key
      if by_key[typed] then
        choice = by_key[typed]
        break
      elseif not is_prefix(typed) then
        -- Not a known sequence: start over from this key.
        if by_key[key] then
          choice = by_key[key]
          break
        end
        typed = is_prefix(key) and key or ''
      end
    end
  end
  M.active = nil
  pcall(vim.api.nvim_win_close, win, true)
  vim.cmd.redraw()
  return choice, table.concat(replay)
end

--- Feed back keys captured during a menu's grace period (as if typed; user mappings apply).
---@param keys string
function M.replay(keys)
  if keys and keys ~= '' then
    vim.api.nvim_feedkeys(keys, 'mt', false)
  end
end

return M
