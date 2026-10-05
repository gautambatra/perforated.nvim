--- Questions to the user: confirmations and one-line text input.
---
--- They follow `toast.backend` like every other message: pop-ups by default (a centred
--- single-key menu, a centred one-line input float), or Neovim's own `vim.fn.confirm` /
--- `vim.ui.input` with `toast.backend = 'notify'` (so a vim.ui.input provider such as
--- snacks.input or dressing applies there).
---
--- Callers use `require('perforated.ui.prompt').confirm(…)` at call time, never a cached
--- local, so tests can replace these two functions.

local M = {}

local function popups()
  return require('perforated.config').get().toast.backend ~= 'notify'
end

--- Like `vim.fn.confirm`: returns the 1-based index of the choice, 0 when cancelled.
--- `choices` uses the same `&Yes\n&No` syntax; the `&` letter chooses (either case) and `<CR>`
--- chooses the default.
---@param msg string
---@param choices string?  default '&Ok'
---@param default integer?  default 1
---@return integer
function M.confirm(msg, choices, default)
  choices = choices or '&Ok'
  default = default or 1
  if not popups() then
    return vim.fn.confirm(msg, choices, default)
  end
  local items = {}
  for i, c in ipairs(vim.split(choices, '\n', { plain = true })) do
    local letter = c:match('&(.)') or c:sub(1, 1)
    local label = c:gsub('&', '', 1)
    items[#items + 1] = {
      key = letter:lower(),
      label = label .. (i == default and '  (<CR>)' or ''),
      value = i,
      aliases = { letter:upper(), i == default and '<CR>' or nil },
    }
  end
  local wrap = require('perforated.ui.toast')._wrap
  local width = math.max(20, math.min(80, vim.o.columns - 10))
  local header = {}
  for _, l in ipairs(vim.split(vim.trim(msg), '\n', { plain = true })) do
    vim.list_extend(header, wrap(l, width))
  end
  local choice = require('perforated.ui.float').menu({
    title = 'Perforce',
    header = header,
    header_hl = false,
    items = items,
    relative = 'editor',
  })
  return choice and choice.value or 0
end

--- Like `vim.ui.input`: `on_confirm(text)`, or `on_confirm(nil)` when cancelled. An empty
--- answer is `''`, not nil. `<CR>` accepts; `<Esc>`, `<C-c>` or leaving the window cancels;
--- with `opts.completion` (a `getcompletion()` type) `<Tab>` completes the word at the cursor.
---@param opts { prompt: string?, default: string?, completion: string? }
---@param on_confirm fun(input: string?)
function M.input(opts, on_confirm)
  opts = opts or {}
  if not popups() then
    return vim.ui.input(opts, on_confirm)
  end
  local title = vim.trim((opts.prompt or 'Input'):gsub(':%s*$', ''))
  local default = opts.default or ''
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 6, vim.fn.strdisplaywidth(default) + 4)
  width = math.min(width, vim.o.columns - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'perforated-input'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - 3) / 2), -- a blocking question: the middle of the screen
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'left',
    footer = ' <CR> ok · <Esc> cancel ',
    footer_pos = 'right',
    zindex = 200,
  })
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  vim.wo[win][0].wrap = false

  local done = false
  local function finish(value)
    if done then
      return
    end
    done = true
    vim.cmd('stopinsert')
    pcall(vim.api.nvim_win_close, win, true)
    -- After the window is gone and insert mode has ended: the answer may open menus or pickers.
    vim.schedule(function()
      on_confirm(value)
    end)
  end
  local function accept()
    finish((vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''))
  end
  local function cancel()
    finish(nil)
  end
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true })
  end
  map({ 'i', 'n' }, '<CR>', accept)
  map({ 'i', 'n' }, '<C-c>', cancel)
  map({ 'i', 'n' }, '<Esc>', cancel)
  map('n', 'q', cancel)
  if opts.completion then
    map('i', '<Tab>', function()
      if vim.fn.pumvisible() == 1 then
        return vim.api.nvim_feedkeys(vim.keycode('<C-n>'), 'n', false)
      end
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local start = (line:sub(1, col):match('.*()%s') or 0) + 1
      local word = line:sub(start, col)
      local ok, matches = pcall(vim.fn.getcompletion, word, opts.completion)
      if ok and #matches > 0 then
        vim.fn.complete(start, matches)
      end
    end)
  end
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = cancel,
  })
  vim.cmd('startinsert!')
end

return M
