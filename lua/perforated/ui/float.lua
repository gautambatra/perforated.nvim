--- Small floating UI helpers: the single-key modal menu (check-out / add prompts).

local M = {}

M.ns = vim.api.nvim_create_namespace('perforated.float')

---@class perforated.MenuItem
---@field key string    keytrans() form, e.g. '<CR>', 'c', 'S'
---@field label string
---@field value any

---@class perforated.MenuOpts
---@field title string
---@field header string[]?     lines shown above the choices
---@field items perforated.MenuItem[]
---@field grace integer?        ms after opening during which keys count as typing, not choices
---@field relative 'cursor'|'editor'|nil

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
  for _, it in ipairs(opts.items) do
    local key = it.key
    lines[#lines + 1] = ('  %-6s %s'):format(key, it.label)
    key_hls[#lines] = #key
  end
  local width = vim.fn.strdisplaywidth(opts.title) + 4
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)

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
  for i = 1, #(opts.header or {}) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, 0, { line_hl_group = 'PerforatedDim' })
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
    by_key[it.key] = it
  end
  local grace = opts.grace or 0
  local opened = vim.uv.now()
  local replay = {}
  local choice
  while true do
    local ok, raw = pcall(vim.fn.getcharstr)
    if not ok then
      break -- <C-c>
    end
    local key = vim.fn.keytrans(raw)
    if vim.uv.now() - opened < grace then
      replay[#replay + 1] = raw
    elseif key == '<Esc>' or key == 'q' or key == '<C-C>' then
      break
    elseif by_key[key] then
      choice = by_key[key]
      break
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
