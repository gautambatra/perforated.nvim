--- The plugin's own picker (`picker = 'perforated'`, and the `'auto'` fallback when no picker
--- plugin is installed): a filter line, a list and an optional preview, as floats.
---
--- The list is an ordinary buffer in a focusable float, so Neovim's own motions work (gg, G,
--- <C-d>, mouse clicks). j/k/<Down>/<Up> wrap around; <CR> (or a double click) chooses; q /
--- <Esc> cancel; `i` or `/` types in the filter line (fuzzy, `matchfuzzypos`, debounced);
--- `m` marks items when the source allows several. Leaving the picker cancels it.
---
--- Cost: one set_lines per filter; matched characters are drawn by a decoration provider for
--- the visible rows only. Nothing is loaded until a picker opens.

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.picker.list')
local DEBOUNCE = 15 -- ms after a keystroke in the filter line: a burst of typing filters once
local MARK = '● '
local NOMARK = '  '

--- State of the open picker (one at a time), for the decoration provider and tests.
M._active = nil

--- Byte positions from matchfuzzypos (character indices) for one string.
local function byte_positions(text, chars)
  if not text:find('[\128-\255]') then
    return chars -- ASCII: characters are bytes
  end
  local out = {}
  for i, c in ipairs(chars) do
    out[i] = vim.str_byteindex(text, 'utf-32', c, false)
  end
  return out
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win)
    local p = M._active
    return p ~= nil and win == p.list_win
  end,
  on_line = function(_, _, buf, row)
    local p = M._active
    if not (p and p.positions) then
      return
    end
    local idx = p.shown[row + 1]
    local pos = p.positions[row + 1]
    if pos == nil and idx then
      -- First time this row is drawn for this filter: one short string, a few microseconds.
      local text = p.texts[idx].text
      local res = vim.fn.matchfuzzypos({ text }, p.q)
      pos = res[2][1] and byte_positions(text, res[2][1]) or false
      p.positions[row + 1] = pos
    end
    if not pos then
      return
    end
    -- Byte positions in the item text, after the mark column (`● ` marked, two spaces not).
    local prefix = p.marks[p.shown[row + 1]] and #MARK or #NOMARK
    for _, c in ipairs(pos) do
      local col = prefix + c
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, {
        end_col = col + 1,
        hl_group = 'PerforatedPickerMatch',
        ephemeral = true,
      })
    end
  end,
})

---@param spec perforated.PickSpec
---@param finish fun(items: any[]?)  called once
function M.open(spec, finish)
  require('perforated.hl').setup() -- can open outside a workspace (`:P4 pick` on a connection)
  local items = spec.items
  local texts = {}
  for i, it in ipairs(items) do
    texts[i] = { text = (spec.format(it):gsub('\n', ' ')), idx = i }
  end

  -- Layout: list (and filter line above it), preview beside it or below on narrow screens.
  local cols, rows = vim.o.columns, vim.o.lines
  local has_preview = spec.preview ~= nil
  local longest = 20
  for _, t in ipairs(texts) do
    longest = math.max(longest, vim.fn.strdisplaywidth(t.text) + #MARK + 1)
  end
  local side = has_preview and cols >= 110
  local total_w = math.min(cols - 6, side and math.max(longest + 50, 100) or math.max(longest, 60))
  local list_w = side and math.min(longest, math.floor(total_w * 0.55)) or total_w
  local avail_h = rows - 8
  local list_h =
    math.max(3, math.min(#items, math.floor(avail_h * (has_preview and not side and 0.5 or 0.7))))
  local prev_h = has_preview
      and (side and list_h + 2 or math.max(3, math.min(12, avail_h - list_h - 5)))
    or 0
  local block_h = list_h + 3 + ((has_preview and not side) and (prev_h + 2) or 0)
  local top = math.max(1, math.floor((rows - block_h) / 2) - 1)
  local left = math.floor((cols - total_w) / 2)

  local function scratch(name)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = 'wipe'
    vim.bo[b].swapfile = false
    vim.b[b].perforated_picker = name
    return b
  end
  local filter_buf, list_buf = scratch('filter'), scratch('list')
  local prev_buf = has_preview and scratch('preview') or nil
  local function float(buf, opts, enter)
    opts = vim.tbl_extend('force', {
      relative = 'editor',
      style = 'minimal',
      border = 'rounded',
      zindex = 150,
    }, opts)
    local w = vim.api.nvim_open_win(buf, enter, opts)
    vim.wo[w][0].winhighlight =
      'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder,CursorLine:PerforatedMenuSel'
    return w
  end
  local count_title = function(n)
    return (' %s  %d/%d '):format(spec.title, n, #items)
  end
  local filter_win = float(filter_buf, {
    row = top,
    col = left,
    width = list_w,
    height = 1,
    title = count_title(#items),
    title_pos = 'left',
  }, false)
  local list_win = float(list_buf, {
    row = top + 3,
    col = left,
    width = list_w,
    height = list_h,
  }, true)
  vim.wo[list_win][0].cursorline = true
  vim.wo[list_win][0].wrap = false
  local prev_win
  if prev_buf then
    prev_win = float(prev_buf, side and {
      row = top,
      col = left + list_w + 2,
      width = total_w - list_w - 2,
      height = prev_h + 1,
      title = ' Preview ',
      title_pos = 'left',
      focusable = false,
    } or {
      row = top + list_h + 5,
      col = left,
      width = total_w,
      height = prev_h,
      title = ' Preview ',
      title_pos = 'left',
      focusable = false,
    }, false)
    vim.wo[prev_win][0].wrap = true
  end
  vim.bo[filter_buf].buftype = 'prompt'
  vim.fn.prompt_setprompt(filter_buf, '> ')

  local p = {
    list_win = list_win,
    filter_win = filter_win,
    prev_win = prev_win,
    list_buf = list_buf,
    filter_buf = filter_buf,
    texts = texts,
    shown = {}, -- row → item index
    positions = nil, -- row → matched byte positions
    marks = {}, -- item index → true
    query = '',
  }
  M._active = p
  local closed = false
  local aug = vim.api.nvim_create_augroup('perforated.picker.list', { clear = true })

  local function close(result)
    if closed then
      return
    end
    closed = true
    M._active = nil
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    if p.timer then
      p.timer:stop()
      p.timer:close()
    end
    vim.cmd.stopinsert()
    for _, w in ipairs({ filter_win, list_win, prev_win }) do
      if w and vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    finish(result)
  end
  p.close = close

  local function update_preview()
    if not prev_buf or not vim.api.nvim_win_is_valid(list_win) then
      return
    end
    local idx = p.shown[vim.api.nvim_win_get_cursor(list_win)[1]]
    local lines = idx and spec.preview(items[idx]) or {}
    vim.bo[prev_buf].modifiable = true
    vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, lines)
    vim.bo[prev_buf].modifiable = false
  end

  local function render()
    local lines = {}
    for row, idx in ipairs(p.shown) do
      lines[row] = (p.marks[idx] and MARK or NOMARK) .. texts[idx].text
    end
    if #lines == 0 then
      lines[1] = NOMARK .. 'no matches'
    end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_win_set_config(filter_win, { title = count_title(#p.shown), title_pos = 'left' })
  end

  -- Matches per query typed so far: typing one more character can only narrow the matches,
  -- so it searches the longest earlier query's matches, not every item (deleting one goes
  -- back to a remembered result).
  local cache = {} ---@type table<string, integer[]>
  local all = {}
  for i = 1, #texts do
    all[i] = i
  end
  cache[''] = all

  -- Text → item index (a list when several items show the same text), built once.
  local strs_all, by_text, dupes = {}, {}, false
  for i, t in ipairs(texts) do
    strs_all[i] = t.text
    local prev = by_text[t.text]
    if prev == nil then
      by_text[t.text] = i
    else
      dupes = true
      by_text[t.text] = type(prev) == 'table' and vim.list_extend(prev, { i }) or { prev, i }
    end
  end

  --- Fuzzy-match `q` among the items `candidates` (indices). Plain strings, no positions
  --- (`matchfuzzy`): converting thousands of position lists to Lua costs as much as the match;
  --- positions are computed only for the rows being drawn (decoration provider).
  local function match(q, candidates)
    local strs = strs_all
    if candidates ~= all then
      strs = {}
      for k, idx in ipairs(candidates) do
        strs[k] = strs_all[idx]
      end
    end
    local res = vim.fn.matchfuzzy(strs, q)
    local shown = {}
    if not dupes then
      for row, t in ipairs(res) do
        shown[row] = by_text[t]
      end
      return shown
    end
    -- Several items with the same text: each once, in order, among the candidates.
    local allowed = {}
    for _, idx in ipairs(candidates) do
      allowed[idx] = true
    end
    local used = {}
    for row, t in ipairs(res) do
      local ids = by_text[t]
      if type(ids) ~= 'table' then
        shown[row] = ids
      else
        local k = used[t] or 0
        repeat
          k = k + 1
        until allowed[ids[k]] or ids[k] == nil
        used[t] = k
        shown[row] = ids[k]
      end
    end
    return shown
  end

  local function apply_filter()
    p.applied = p.query
    local q = vim.trim(p.query)
    p.q = q
    if q == '' then
      p.shown, p.positions = all, nil
    else
      local base = ''
      for prev in pairs(cache) do
        if #prev > #base and q:sub(1, #prev) == prev then
          base = prev
        end
      end
      p.shown, p.positions = match(q, cache[base]), {}
      cache[q] = p.shown
    end
    render()
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    end
    update_preview()
  end
  p.apply_filter = apply_filter

  -- Choose: the marked items (multi), else the one under the cursor.
  local function read_query()
    local line = vim.api.nvim_buf_get_lines(filter_buf, 0, 1, false)[1] or ''
    p.query = line:gsub('^> ', '')
  end
  local function choose()
    -- Typed faster than TextChangedI / the debounce (keys still queued): use the filter line as
    -- it is now.
    read_query()
    if p.applied ~= p.query then
      apply_filter()
    end
    if #p.shown == 0 then
      return
    end
    local chosen = {}
    if spec.multi and next(p.marks) then
      for i = 1, #items do
        if p.marks[i] then
          chosen[#chosen + 1] = items[i]
        end
      end
    else
      local idx = p.shown[vim.api.nvim_win_get_cursor(list_win)[1]]
      chosen = idx and { items[idx] } or {}
    end
    close(#chosen > 0 and chosen or nil)
  end
  local function move(delta)
    local n = math.max(#p.shown, 1)
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    vim.api.nvim_win_set_cursor(list_win, { (row - 1 + delta) % n + 1, 0 })
  end
  local function to_filter()
    vim.api.nvim_set_current_win(filter_win)
    vim.cmd.startinsert({ bang = true })
  end

  -- List keys.
  local function lmap(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = list_buf, nowait = true })
  end
  for _, lhs in ipairs({ 'j', '<Down>' }) do
    lmap(lhs, function()
      move(vim.v.count1)
    end)
  end
  for _, lhs in ipairs({ 'k', '<Up>' }) do
    lmap(lhs, function()
      move(-vim.v.count1)
    end)
  end
  lmap('<CR>', choose)
  lmap('<2-LeftMouse>', choose)
  for _, lhs in ipairs({ 'q', '<Esc>', '<C-c>' }) do
    lmap(lhs, function()
      close(nil)
    end)
  end
  for _, lhs in ipairs({ 'i', '/', 'a' }) do
    lmap(lhs, to_filter)
  end
  if spec.multi then
    lmap('m', function()
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      local idx = p.shown[row]
      if idx then
        p.marks[idx] = not p.marks[idx] or nil
        render()
        vim.api.nvim_win_set_cursor(list_win, { row, 0 })
        move(1)
      end
    end)
  end

  -- Filter-line keys (insert mode): typing filters; arrows move the list; <CR> chooses.
  local function imap(lhs, fn)
    vim.keymap.set('i', lhs, fn, { buffer = filter_buf, nowait = true })
  end
  imap('<CR>', choose)
  imap('<Esc>', function()
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(list_win)
  end)
  imap('<C-c>', function()
    close(nil)
  end)
  for _, lhs in ipairs({ '<Down>', '<C-n>', '<C-j>' }) do
    imap(lhs, function()
      vim.api.nvim_win_call(list_win, function()
        move(1)
      end)
      update_preview()
    end)
  end
  for _, lhs in ipairs({ '<Up>', '<C-p>', '<C-k>' }) do
    imap(lhs, function()
      vim.api.nvim_win_call(list_win, function()
        move(-1)
      end)
      update_preview()
    end)
  end
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = aug,
    buffer = filter_buf,
    callback = function()
      read_query()
      p.timer = p.timer or vim.uv.new_timer()
      p.timer:stop()
      p.timer:start(
        DEBOUNCE,
        0,
        vim.schedule_wrap(function()
          if not closed then
            apply_filter()
          end
        end)
      )
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = aug,
    buffer = list_buf,
    callback = update_preview,
  })
  -- Leaving the picker (another window, a tab switch) cancels it; moving between the filter
  -- line and the list doesn't.
  vim.api.nvim_create_autocmd('WinEnter', {
    group = aug,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if w ~= list_win and w ~= filter_win then
        close(nil)
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = aug,
    pattern = { tostring(list_win), tostring(filter_win) },
    callback = function()
      vim.schedule(function()
        close(nil)
      end)
    end,
  })

  apply_filter()
  if require('perforated.config').get().picker_mode == 'insert' then
    to_filter()
  end
  return p
end

return M
