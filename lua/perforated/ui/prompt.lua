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

-- ---------------------------------------------------------------------------------------------
-- Keys typed ahead of a question
--
-- A view action that asks p4 something before its question (shelve: what's in the shelf?)
-- leaves a gap in which the view is live: a key typed for the coming question would run
-- another action instead (`S` then `r` reverted the files). Three guards:
-- - while a question is on its way (`hold`), view actions don't run (`keys.dispatch`);
-- - keys pressed in the first `toast.confirm_grace` ms of a confirmation don't answer it;
-- - a confirmation opened by a view action never answers to that action's key (`r` twice
--   doesn't revert): the choice with that letter gets another one (`y` when free).
-- ---------------------------------------------------------------------------------------------

--- A hold not released by then lapses (a safety net: callers release it when p4 answers).
M.HOLD_MAX_MS = 60000

local holds = {} ---@type table<table, string>

--- The key of the view action running now (`opener`), kept while a question it holds for
--- is on its way. `holds`: how many of those are.
---@type { keys: table<string, true>, holds: integer }?
M.opener = nil

--- A question is on its way: until `release()`, view actions don't run (the keys typed
--- meanwhile were meant for it). Release it when p4 has answered, before asking.
---@param what string  what is being checked, for the note ("CL 5's shelf")
---@return fun() release
function M.hold(what)
  local id, opener = {}, M.opener
  holds[id] = what
  if opener then
    opener.holds = opener.holds + 1
  end
  local released = false
  local function release()
    if released then
      return
    end
    released = true
    holds[id] = nil
    if opener then
      opener.holds = opener.holds - 1
      if opener.holds == 0 then
        -- (After the question this callback is about to ask.)
        vim.schedule(function()
          if M.opener == opener and opener.holds == 0 then
            M.opener = nil
          end
        end)
      end
    end
  end
  vim.defer_fn(release, M.HOLD_MAX_MS)
  return release
end

--- What a question on its way is waiting for, or nil.
---@return string?
function M.held()
  local _, what = next(holds)
  return what
end

--- A view action started by `lhs` begins (`keys.dispatch`); returns its end, called when its
--- `run` returns. Its questions don't answer to the letters of `lhs` (case aside).
---@param lhs string?
---@return fun() finish
function M.begin(lhs)
  local keys = {}
  for c in ((lhs or ''):gsub('<[^>]*>', '')):gmatch('%w') do
    keys[c:lower()] = true
  end
  local opener = next(keys) and { keys = keys, holds = 0 } or nil
  M.opener = opener
  return function()
    if M.opener == opener and (not opener or opener.holds == 0) then
      M.opener = nil
    end
  end
end

--- Choices `{ letter, label, given }` from `&Yes\n&No`; one whose letter is the running
--- action's key gets another (`y`, else a free letter of its label, else a digit). Cancel
--- keeps its own (answering it twice is harmless).
---@param choices string
---@return { letter: string, label: string, given: string }[]
local function parse_choices(choices)
  local list = {}
  for _, c in ipairs(vim.split(choices, '\n', { plain = true })) do
    list[#list + 1] =
      { letter = (c:match('&(.)') or c:sub(1, 1)):lower(), label = (c:gsub('&', '', 1)), given = c }
  end
  local o = M.opener
  if not o then
    return list
  end
  local used = {}
  for _, c in ipairs(list) do
    used[c.letter] = true
  end
  for _, c in ipairs(list) do
    if o.keys[c.letter] and not c.label:match('^Cancel') then
      local cands = { 'y' }
      for ch in c.label:lower():gmatch('%w') do
        cands[#cands + 1] = ch
      end
      for d = 1, 9 do
        cands[#cands + 1] = tostring(d)
      end
      for _, cand in ipairs(cands) do
        if not used[cand] and not o.keys[cand] then
          used[cand], c.letter, c.given = true, cand, nil
          break
        end
      end
    end
  end
  return list
end

--- Like `vim.fn.confirm`: returns the 1-based index of the choice, 0 when cancelled.
--- `choices` uses the same `&Yes\n&No` syntax; the `&` letter chooses (either case) and `<CR>`
--- chooses the default. Keys pressed in its first `toast.confirm_grace` ms don't answer it, and
--- one opened by a view action doesn't answer to that action's key (see above).
---@param msg string
---@param choices string?  default '&Ok'
---@param default integer?  default 1
---@return integer
function M.confirm(msg, choices, default)
  choices = choices or '&Ok'
  default = default or 1
  local list = parse_choices(choices)
  if not popups() then
    -- (No grace here: what was typed ahead of it is dropped instead.)
    local typed = vim.fn.getchar(0)
    while typed ~= 0 do
      typed = vim.fn.getchar(0)
    end
    local given = vim.tbl_map(function(c)
      if c.given then
        return c.given
      end
      local at = c.label:lower():find(c.letter, 1, true)
      return at and (c.label:sub(1, at - 1) .. '&' .. c.label:sub(at))
        or (c.label .. ' (&' .. c.letter .. ')')
    end, list)
    return vim.fn.confirm(msg, table.concat(given, '\n'), default)
  end
  local items = {}
  for i, c in ipairs(list) do
    local letter, label = c.letter, c.label
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
    -- (Pressed in the grace period, keys are dropped: confirm doesn't replay them.)
    grace = require('perforated.config').get().toast.confirm_grace,
  })
  return choice and choice.value or 0
end

--- Like `vim.ui.input`: `on_confirm(text)`, or `on_confirm(nil)` when cancelled. An empty
--- answer is `''`, not nil. `<CR>` accepts; `<Esc>`, `<C-c>` or leaving the window cancels;
--- with `opts.completion` (a `getcompletion()` type) `<Tab>` completes the word at the cursor
--- (`dir` / `file`: a space in a name is `\ `, as on the command line).
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
  require('perforated.ui.bufname').set(buf, 'input')
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
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedInputBorder'
  -- A prominent border (not the usual accent): a question waiting for an answer.
  require('perforated.ui.stack').register(win, { border = 'PerforatedInputBorder' })
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
      -- File and directory names: a space in one is `\ ` (as on the command line), both in
      -- the word being completed and in what completion inserts.
      local esc = opts.completion == 'dir' or opts.completion == 'file'
      local start, i = 1, 1
      while i <= col do
        local c = line:sub(i, i)
        if esc and c == '\\' then
          i = i + 1
        elseif c:match('%s') then
          start = i + 1
        end
        i = i + 1
      end
      local word = line:sub(start, col)
      if esc then
        word = word:gsub('\\(.)', '%1')
      end
      local ok, matches = pcall(vim.fn.getcompletion, word, opts.completion)
      if ok and esc then
        matches = vim.tbl_map(function(m)
          return (m:gsub('([\\%s])', '\\%1'))
        end, matches)
      end
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
