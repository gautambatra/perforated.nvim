--- Non-intrusive notifications ("toasts").
---
--- * Floats centred horizontally, never focusable. Where they sit says what they are:
---   - `center`: blocking — you're waiting on it ("Opening diff view…"); middle of the screen;
---   - `action` (the default): the result of something you just did; near the top, stacking
---     downwards;
---   - `background`: news you didn't ask for just now (stale files, a finished job); at the
---     bottom above the statusline, stacking upwards.
--- * Activity-gated: the dismissal countdown starts at the user's first keypress after the toast
---   is shown, so a toast can't vanish while nobody is looking.
--- * Focus-gated: toasts raised while Neovim is unfocused are queued until FocusGained.
--- * History (`:P4 messages`); `toast.timeout = 0` = sticky until `:P4 dismiss`;
---   `toast.backend = 'notify'` routes to vim.notify instead.
--- * Every plugin message goes through `M.notify` (a toast by default), not only stale files.

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.toast')
local key_ns = vim.api.nvim_create_namespace('perforated.toast.keys')

---@class perforated.Toast
---@field title string
---@field lines string[]
---@field level integer?
---@field time integer?
---@field win integer?
---@field timer uv.uv_timer_t?
---@field counting boolean?
---@field place 'center'|'action'|'background'|nil  default 'action'
---@field busy boolean?

local shown = {} ---@type perforated.Toast[]
local queued = {} ---@type perforated.Toast[]
local history = {} ---@type perforated.Toast[]
M.focused = true
local did_setup = false

local function cfg()
  return require('perforated.config').get().toast
end

local function setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup('perforated.toast', { clear = true })
  vim.api.nvim_create_autocmd('FocusLost', {
    group = group,
    callback = function()
      M.focused = false
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M.focused = true
      local q = queued
      queued = {}
      for _, t in ipairs(q) do
        M._render(t)
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', { group = group, callback = M._restack })
end

local function close(t)
  if t.timer then
    t.timer:stop()
    if not t.timer:is_closing() then
      t.timer:close()
    end
    t.timer = nil
  end
  if t.win and vim.api.nvim_win_is_valid(t.win) then
    pcall(vim.api.nvim_win_close, t.win, true)
  end
  t.win = nil
  for i, s in ipairs(shown) do
    if s == t then
      table.remove(shown, i)
      break
    end
  end
  M._restack()
end

--- Lay out the visible toasts: each placement is its own stack, centred horizontally.
--- Action toasts start two lines below the top edge (below the tabline) and stack downwards,
--- oldest first; background toasts sit above the statusline and stack upwards, newest at the
--- bottom; centre toasts are centred as a group.
function M._restack()
  local groups = { center = {}, action = {}, background = {} }
  for _, t in ipairs(shown) do
    if t.win and vim.api.nvim_win_is_valid(t.win) then
      local c = vim.api.nvim_win_get_config(t.win)
      local g = groups[t.place or 'action'] or groups.action
      g[#g + 1] = { win = t.win, width = c.width, height = c.height + 2 } -- + border
    end
  end
  local function put(e, row)
    vim.api.nvim_win_set_config(e.win, {
      relative = 'editor',
      row = math.max(row, 0),
      col = math.max(math.floor((vim.o.columns - e.width - 2) / 2), 0),
    })
  end
  local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and vim.fn.tabpagenr('$') > 1))
      and 1
    or 0
  local row = tabline + 1
  for _, e in ipairs(groups.action) do
    put(e, row)
    row = row + e.height
  end
  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  for i = #groups.background, 1, -1 do
    local e = groups.background[i]
    bottom = bottom - e.height
    put(e, bottom)
  end
  local total = 0
  for _, e in ipairs(groups.center) do
    total = total + e.height
  end
  row = math.floor((vim.o.lines - total) / 2)
  for _, e in ipairs(groups.center) do
    put(e, row)
    row = row + e.height
  end
end

local function start_countdown(t)
  local timeout = cfg().timeout
  if t.counting or t.busy or timeout <= 0 or not t.win then
    return
  end
  t.counting = true
  t.timer = vim.uv.new_timer()
  t.timer:start(timeout, 0, function()
    vim.schedule(function()
      close(t)
    end)
  end)
end

--- Start countdowns on the first key the user presses after toasts were shown.
local function arm_activity()
  vim.on_key(function()
    vim.on_key(nil, key_ns)
    vim.schedule(function()
      for _, t in ipairs(shown) do
        start_countdown(t)
      end
    end)
  end, key_ns)
end

--- Split a line into pieces at most `width` display cells wide, at spaces where possible.
---@param line string
---@param width integer
---@return string[]
local function wrap(line, width)
  local out = {}
  while vim.fn.strdisplaywidth(line) > width do
    local cut = vim.fn.byteidx(line, width) -- byte index of the first char that doesn't fit
    if cut <= 0 then
      break
    end
    local head = line:sub(1, cut)
    local space = head:match('.*() ')
    if space and space > width / 3 then
      out[#out + 1] = line:sub(1, space - 1)
      line = line:sub(space + 1)
    else
      out[#out + 1] = head
      line = line:sub(cut + 1)
    end
  end
  out[#out + 1] = line
  return out
end

M._wrap = wrap

local BORDER = {
  [vim.log.levels.ERROR] = 'PerforatedToastErrorBorder',
  [vim.log.levels.INFO] = 'PerforatedToastInfoBorder',
}

---@param t perforated.Toast
function M._render(t)
  local max = math.max(20, math.floor(vim.o.columns * 0.6))
  local lines = {}
  for _, l in ipairs(t.lines) do
    for _, piece in ipairs(wrap(l, max - 2)) do
      lines[#lines + 1] = ' ' .. piece .. ' '
    end
  end
  local width = vim.fn.strdisplaywidth(t.title) + 4
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, max)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if t.detail then
    -- Stale-file toasts end with a details line (revision, CL, user).
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, { line_hl_group = 'PerforatedDim' })
  end
  t.win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. t.title .. ' ',
    title_pos = 'left',
    focusable = false,
    noautocmd = true,
    zindex = 150,
  })
  local level = t.level or vim.log.levels.WARN
  local border = BORDER[level]
    or (level < vim.log.levels.INFO and BORDER[vim.log.levels.INFO])
    or 'PerforatedToastBorder'
  vim.wo[t.win][0].winhighlight = 'NormalFloat:PerforatedToast,FloatBorder:' .. border
  vim.wo[t.win][0].wrap = false
  shown[#shown + 1] = t
  M._restack()
  arm_activity()
end

--- Show a toast (or queue it until focus returns).
---@param title string
---@param lines string[]
---@param level integer?
---@param opts { detail: boolean?, place: 'center'|'action'|'background'|nil }?  detail: the last
--- line is a (dimmed) details line; place: see the module header (default 'action')
function M.show(title, lines, level, opts)
  setup()
  local t = {
    title = title,
    lines = lines,
    level = level,
    time = os.time(),
    detail = opts and opts.detail,
    place = opts and opts.place,
  }
  require('perforated.core.debug').info(
    'toast',
    '%s: %s (focused=%s backend=%s)',
    title,
    table.concat(lines, ' | '),
    tostring(M.focused),
    cfg().backend
  )
  table.insert(history, t)
  local max = cfg().history
  while #history > max do
    table.remove(history, 1)
  end
  if cfg().backend == 'notify' then
    vim.notify(title .. '\n' .. table.concat(lines, '\n'), level or vim.log.levels.WARN)
    return
  end
  if not M.focused then
    queued[#queued + 1] = t
    return
  end
  M._render(t)
end

local TITLES = {
  [vim.log.levels.ERROR] = 'Perforce: error',
  [vim.log.levels.WARN] = 'Perforce: warning',
}

--- A plugin message: a toast titled by its level, or `vim.notify` when
--- `toast.backend = 'notify'`. Safe to call from any context.
---@param msg string
---@param level integer?  vim.log.levels (default INFO)
---@param opts { place: 'center'|'action'|'background'|nil }?  default 'action': the result of
--- what the user just did; 'background' for news from polling or a job finishing later
function M.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  msg = tostring(msg):gsub('^%[perforated%] ', '')
  if vim.in_fast_event() then
    return vim.schedule(function()
      M.notify(msg, level, opts)
    end)
  end
  if cfg().backend == 'notify' then
    return vim.notify('[perforated] ' .. msg, level)
  end
  M.show(
    TITLES[level] or 'Perforce',
    vim.split(msg, '\n', { plain = true, trimempty = true }),
    level,
    { place = opts and opts.place }
  )
end

--- A "working on it" pop-up for an action that takes a moment (e.g. "Opening diff view…"):
--- shown at once, no countdown, not in the history. Returns the function that closes it; call
--- it on every outcome. With `toast.backend = 'notify'` it's a plain vim.notify.
---@param msg string
---@return fun() close
function M.busy(msg)
  if cfg().backend == 'notify' then
    vim.notify('[perforated] ' .. msg, vim.log.levels.INFO)
    return function() end
  end
  setup()
  local t = {
    title = 'Perforce',
    lines = { msg },
    level = vim.log.levels.INFO,
    busy = true,
    place = 'center',
  }
  M._render(t)
  vim.cmd.redraw() -- now: the work that follows may keep the main loop busy for a while
  return function()
    close(t)
  end
end

--- Close every toast.
function M.dismiss()
  for i = #shown, 1, -1 do
    close(shown[i])
  end
  queued = {}
end

---@return perforated.Toast[]
function M.history()
  return history
end

--- Currently visible toasts (tests / statusline).
function M.visible()
  return shown
end

--- Open the toast history in a scratch buffer.
function M.open_history()
  local lines = {}
  for i = #history, 1, -1 do
    local t = history[i]
    lines[#lines + 1] = os.date('%H:%M:%S ', t.time) .. t.title
    for _, l in ipairs(t.lines) do
      lines[#lines + 1] = '    ' .. l
    end
  end
  if #lines == 0 then
    lines = { '(no messages)' }
  end
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'perforated-messages'
  vim.api.nvim_win_set_height(0, math.min(15, #lines))
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true })
end

function M._reset()
  M.dismiss()
  history, queued = {}, {}
  M.focused = true
end

return M
