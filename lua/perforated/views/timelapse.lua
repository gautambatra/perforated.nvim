--- Time-lapse view (`:P4 timelapse`, `t`, `<C-S-t>`): a read-only buffer that steps through a
--- file's revisions instantly (see timelapse.lua: every revision is rebuilt in memory from one
--- `annotate -a`). The winbar shows `#N/#head · CL · user · date · description`; lines added at
--- N are highlighted and deleted lines are shown where they were (virtual lines). The cursor
--- stays on the same line of the file as you step.

local engine = require('perforated.timelapse')
local keys = require('perforated.ui.keys')

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.timelapse')

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

--- Revision metadata line for the winbar.
local function winbar(view)
  local tl, n = view.tl, view.n
  local r = tl.revs[n] or {}
  local t = tonumber(r.time)
  local text = ('#%d/#%d · CL %s · %s · %s · %s%s'):format(
    n,
    tl.head,
    r.change or '?',
    r.user or '?',
    t and os.date('%Y-%m-%d', t) or '',
    r.action or '',
    first_line(r.desc) ~= '' and (' · ' .. first_line(r.desc)) or ''
  )
  return ' ' .. text:gsub('%%', '%%%%')
end

--- Show revision n, keeping the cursor on the same line of the file.
---@param view table
---@param n integer
local function is_deleted(tl, n)
  local r = tl.revs[n]
  return r and (r.action == 'delete' or r.action == 'move/delete' or r.action == 'purge')
end

function M.show(view, n)
  local t0 = vim.uv.hrtime()
  local tl = view.tl
  local buf = view.buf
  local lnum = 1
  vim.bo[buf].modifiable = true
  if view.n and not is_deleted(tl, view.n) and not is_deleted(tl, n) then
    -- Edit only the lines that differ between the two revisions.
    local cur = vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_cursor(view.win)[1]
      or 1
    local edits, added, removed
    edits, lnum, added, removed = engine.transition(tl, view.n, n, cur)
    view.changes = { n = n, added = added, removed = removed }
    for _, e in ipairs(edits) do
      vim.api.nvim_buf_set_lines(buf, e.start, e.start + e.del, false, e.ins)
    end
  else
    local lines = engine.revision(tl, n)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })
    lnum = view.n and 1 or (view.start_line or 1)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  view.n = n
  M.decorate(view)
  if vim.api.nvim_win_is_valid(view.win) then
    vim.wo[view.win].winbar = winbar(view)
    local count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, view.win, { math.max(1, math.min(lnum, count)), 0 })
  end
  if view.mode == 'diff' then
    M.update_diff(view)
  end
  if view.slider then
    view.slider:render()
  end
  require('perforated.core.debug').timing('time-lapse: step', (vim.uv.hrtime() - t0) / 1e6)
  if view.footer then
    view.footer:set(keys.footer(view.actions, view.tree:node_at()))
  end
end

--- Highlights: added lines, deleted lines (virtual lines), the optional age gutter.
function M.decorate(view)
  local tl, n, buf = view.tl, view.n, view.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if view.mode == 'diff' then
    return -- the diff highlighting says it all
  end
  if view.mode == 'range' then
    return M.decorate_range(view)
  end
  local ch = view.changes
  local added, removed
  if ch and ch.n == n then
    added, removed = ch.added, ch.removed
  else
    added, removed = engine.changes(tl, n)
  end
  if n ~= tl.first then
    for _, l in ipairs(added) do
      vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = 'PerforatedTimelapseAdd' })
    end
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for l, texts in pairs(removed) do
    local virt = {}
    for _, t in ipairs(texts) do
      virt[#virt + 1] = { { t, 'PerforatedTimelapseDelete' } }
    end
    if l == 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, count - 1, 0, { virt_lines = virt })
    else
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        l - 1,
        0,
        { virt_lines = virt, virt_lines_above = true }
      )
    end
  end
  if view.age then
    local _, idx = engine.revision(tl, n)
    local span = math.max(1, tl.last - tl.first)
    for l, i in ipairs(idx) do
      local lo = tl.entries[i].lo
      local step = 1 + math.floor((lo - tl.first) * 9 / span)
      vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
        virt_text = { { ('%4s '):format('#' .. lo), 'PerforatedAge' .. step } },
        virt_text_pos = 'inline',
      })
    end
  end
end

--- Range mode: revision ● with everything changed since ◆ — added lines coloured by the
--- revision that added them (with `#rev` at the end), deleted lines shown where they were.
function M.decorate_range(view)
  local tl, a, b, buf = view.tl, view.a, view.n, view.buf
  require('perforated.views.annotate').define_age_groups()
  local added, removed = engine.range(tl, a, b)
  local span = math.max(1, b - a - 1)
  local function step(rev)
    return 'PerforatedAge' .. (1 + math.floor((rev - a - 1) * 9 / span))
  end
  for _, ad in ipairs(added) do
    vim.api.nvim_buf_set_extmark(buf, ns, ad[1] - 1, 0, {
      line_hl_group = 'PerforatedTimelapseAdd',
      virt_text = { { ' #' .. ad[2], step(ad[2]) } },
      virt_text_pos = 'eol',
    })
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for l, items in pairs(removed) do
    local virt = {}
    for _, it in ipairs(items) do
      virt[#virt + 1] = {
        { it.text, 'PerforatedTimelapseDelete' },
        { '  −#' .. it.rev, step(math.min(it.rev, b)) },
      }
    end
    if l == 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, count - 1, 0, { virt_lines = virt })
    else
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        l - 1,
        0,
        { virt_lines = virt, virt_lines_above = true }
      )
    end
  end
end

--- Incremental diff mode: revision ◆ in a window on the left, diffed against ● (the main view).
function M.update_diff(view)
  local tl = view.tl
  if not (view.dwin and vim.api.nvim_win_is_valid(view.dwin)) then
    local dbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[dbuf].bufhidden = 'wipe'
    pcall(vim.api.nvim_buf_set_name, dbuf, 'perforated://timelapse-base/' .. tl.depotFile)
    vim.bo[dbuf].filetype = vim.bo[view.buf].filetype
    vim.api.nvim_win_call(view.win, function()
      vim.cmd('leftabove vsplit')
    end)
    view.dwin = vim.fn.win_getid(vim.fn.winnr('h'), vim.api.nvim_win_get_tabpage(view.win))
    if view.dwin == 0 or view.dwin == view.win then
      view.dwin = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_win_set_buf(view.dwin, dbuf)
    view.dbuf, view.da = dbuf, nil
    require('perforated.diff.view').diffthis({ view.dwin, view.win })
    vim.api.nvim_set_current_win(view.win)
  end
  if view.da ~= view.a then
    local lines = engine.revision(tl, view.a)
    vim.bo[view.dbuf].modifiable = true
    vim.api.nvim_buf_set_lines(view.dbuf, 0, -1, false, #lines > 0 and lines or { '' })
    vim.bo[view.dbuf].modifiable = false
    view.da = view.a
  end
  local r = tl.revs[view.a] or {}
  local t = tonumber(r.time)
  vim.wo[view.dwin].winbar = (' ◆ #%d · CL %s · %s · %s'):format(
    view.a,
    r.change or '?',
    r.user or '?',
    t and os.date('%Y-%m-%d', t) or ''
  )
  pcall(vim.api.nvim_win_call, view.win, function()
    vim.cmd('diffupdate')
  end)
end

local function leave_diff(view)
  if view.dwin and vim.api.nvim_win_is_valid(view.dwin) then
    pcall(vim.api.nvim_win_close, view.dwin, true)
  end
  view.dwin, view.dbuf, view.da = nil, nil, nil
  if vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_call, view.win, function()
      vim.cmd('diffoff')
    end)
  end
end

--- Switch mode: 'single' | 'diff' (incremental diff ◆ vs ●) | 'range' (changes since ◆).
function M.set_mode(view, mode)
  if view.mode == 'diff' and mode ~= 'diff' then
    leave_diff(view)
  end
  view.mode = mode
  if mode ~= 'single' and not (view.a and view.a < view.n) then
    view.a = engine.step(view.tl, view.n, -1) or view.n
  end
  if mode == 'diff' then
    M.update_diff(view)
  end
  M.decorate(view)
  if view.slider then
    view.slider:render()
  end
end

local function go(view, n)
  if n and view.tl.revs[n] then
    if view.mode ~= 'single' and view.a and n <= view.a then
      view.a = engine.step(view.tl, n, -1) or n -- keep ◆ before ●
    end
    M.show(view, n)
  end
end

--- Move ◆ (diff / range mode), keeping it before ●.
local function go_a(view, n)
  if not n or not view.tl.revs[n] or n >= view.n then
    return
  end
  view.a = n
  if view.mode == 'diff' then
    M.update_diff(view)
  end
  M.decorate(view)
  if view.slider then
    view.slider:render()
  end
end

local function spec_of(view, n)
  return view.tl.depotFile .. '#' .. n
end

local function actions(view)
  local ws = view.ws
  local function rev()
    return view.tl.revs[view.n] or {}
  end
  return {
    {
      id = 'prev',
      desc = 'Previous revision',
      keys = { '[r', 'h' },
      footer = 1,
      run = function()
        go(view, engine.step(view.tl, view.n, -1))
      end,
    },
    {
      id = 'next',
      desc = 'Next revision',
      keys = { ']r', 'l' },
      footer = 2,
      run = function()
        go(view, engine.step(view.tl, view.n, 1))
      end,
    },
    {
      id = 'first',
      desc = 'First revision',
      keys = { '[R' },
      run = function()
        go(view, view.tl.first)
      end,
    },
    {
      id = 'last',
      desc = 'Last revision',
      keys = { ']R' },
      run = function()
        go(view, view.tl.head)
      end,
    },
    {
      id = 'mode',
      desc = 'Mode: single / incremental diff / range',
      keys = { 'm' },
      footer = 3,
      run = function()
        local nxt = { single = 'diff', diff = 'range', range = 'single' }
        M.set_mode(view, nxt[view.mode or 'single'])
      end,
    },
    {
      id = 'a_prev',
      desc = 'Move ◆ back (diff / range mode)',
      keys = { 'H', '[a' },
      run = function()
        if view.mode ~= 'single' then
          go_a(view, engine.step(view.tl, view.a, -1))
        end
      end,
    },
    {
      id = 'a_next',
      desc = 'Move ◆ forward (diff / range mode)',
      keys = { 'L', ']a' },
      run = function()
        if view.mode ~= 'single' then
          go_a(view, engine.step(view.tl, view.a, 1))
        end
      end,
    },
    {
      id = 'slider',
      desc = 'Show / hide the slider',
      keys = { 's' },
      run = function()
        if view.slider and vim.api.nvim_win_is_valid(view.slider.win) then
          view.slider:close()
          view.slider = nil
        else
          view.slider = require('perforated.views.slider').attach(view, function(n)
            go(view, n)
          end)
        end
      end,
    },
    {
      id = 'scale',
      desc = 'Slider labels: revision / changelist / date',
      keys = { 'S' },
      run = function()
        local nxt = { rev = 'change', change = 'date', date = 'rev' }
        view.scale = nxt[view.scale or 'rev']
        if view.slider then
          view.slider:render()
        end
      end,
    },
    {
      id = 'goto',
      desc = 'Go to revision (#N) or changelist (@CL)',
      keys = { 'r' },
      footer = 3,
      run = function()
        vim.ui.input({ prompt = 'Revision (#N, or @CL): ' }, function(input)
          if not input or vim.trim(input) == '' then
            return
          end
          input = vim.trim(input)
          local cl = input:match('^@(%d+)$')
          if cl then
            -- the revision in effect at that changelist
            local best
            for n, r in pairs(view.tl.revs) do
              if tonumber(r.change) <= tonumber(cl) and (not best or n > best) then
                best = n
              end
            end
            return go(view, best)
          end
          go(view, tonumber(input:match('^#?(%d+)$')))
        end)
      end,
    },
    {
      id = 'pick',
      desc = 'Pick a revision by description',
      keys = { 'T' },
      footer = 4,
      run = function()
        local items = {}
        for n = view.tl.head, view.tl.first, -1 do
          if view.tl.revs[n] then
            items[#items + 1] = view.tl.revs[n]
          end
        end
        require('perforated.picker').pick({
          title = 'Time-lapse · ' .. view.tl.depotFile,
          items = items,
          format = function(r)
            local t = tonumber(r.time)
            return ('#%-4s CL %-8s %s %-12s %s'):format(
              r.rev,
              r.change,
              t and os.date('%Y-%m-%d', t) or '',
              r.user or '',
              first_line(r.desc)
            )
          end,
          on_choice = function(chosen)
            if chosen then
              go(view, tonumber(chosen[1].rev))
            end
          end,
        })
      end,
    },
    {
      id = 'diff',
      desc = 'Diff against the previous revision',
      keys = { 'd' },
      p4v = { '<C-d>' },
      footer = 5,
      run = function()
        local prev = engine.step(view.tl, view.n, -1)
        require('perforated.revs').diff(
          ws,
          prev and { spec = spec_of(view, prev) } or { empty = 'added' },
          { spec = spec_of(view, view.n) }
        )
      end,
    },
    {
      id = 'describe',
      desc = 'Describe changelist',
      keys = { 'D', 'gd' },
      footer = 6,
      run = function()
        require('perforated.views.describe').open(ws, rev().change)
      end,
    },
    {
      id = 'view_change',
      desc = 'View changelist',
      keys = { 'K' },
      run = function()
        require('perforated.views.change_info').open(ws, { change = rev().change })
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      run = function()
        vim.fn.setreg('"', rev().change)
        pcall(vim.fn.setreg, '+', rev().change)
        notify('copied ' .. rev().change)
      end,
    },
    {
      id = 'to_loclist',
      desc = 'Lines added in this revision to the location list',
      keys = { 'Q' },
      run = function()
        local qf = require('perforated.ui.qf')
        local added = engine.changes(view.tl, view.n)
        local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
        local items = {}
        for _, l in ipairs(added) do
          items[#items + 1] = {
            bufnr = view.buf,
            lnum = l,
            text = lines[l],
            user_data = {
              depotFile = view.tl.depotFile,
              rev = tostring(view.n),
              change = rev().change,
            },
          }
        end
        qf.set({
          title = ('P4 time-lapse · #%d · %s'):format(view.n, view.tl.depotFile),
          kind = 'timelapse',
          items = items,
          loclist = true,
          win = view.win,
        })
      end,
    },
    {
      id = 'age',
      desc = 'Toggle the age gutter',
      keys = { 'a' },
      run = function()
        view.age = not view.age
        if view.age then
          require('perforated.views.annotate').define_age_groups()
        end
        M.decorate(view)
      end,
    },
    {
      id = 'annotate',
      desc = 'Annotate this revision',
      keys = { 'b' },
      run = function()
        require('perforated.views.annotate').open_spec(ws, spec_of(view, view.n))
      end,
    },
    {
      id = 'history',
      desc = 'File history',
      keys = { 'gL' },
      p4v = { '<C-t>' },
      run = function()
        require('perforated.views.history').open(ws, view.tl.depotFile)
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      nomenu = true,
      run = function()
        if #vim.api.nvim_list_tabpages() > 1 then
          vim.cmd('tabclose')
        else
          vim.cmd('bwipeout')
        end
      end,
    },
    {
      id = 'help',
      desc = 'Help',
      keys = { '?' },
      nomenu = true,
      run = function()
        keys.help(view.actions, 'Time-lapse')
      end,
    },
    {
      id = 'menu',
      desc = 'Action menu',
      keys = { '.', '<RightMouse>' },
      nomenu = true,
      run = function()
        keys.menu(view.actions, view)
      end,
    },
  }
end

--- Open the time-lapse of a file.
---@param ws perforated.Workspace
---@param path string  depot or local path
---@param opts { rev: integer?, line: integer? }?  start revision (default: newest) and line
function M.open(ws, path, opts)
  opts = opts or {}
  path = path:gsub('[#@].*$', '')
  require('perforated.hl').setup()
  vim.cmd('tabnew')
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.b[buf].perforated_ws = ws.key
  pcall(vim.api.nvim_buf_set_name, buf, 'perforated://timelapse/' .. path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'loading time-lapse of ' .. path .. ' …' })
  vim.bo[buf].modifiable = false
  vim.wo[win].winbar = ' time-lapse · loading…'
  local view = { ws = ws, buf = buf, win = win, start_line = opts.line }
  view.tree = {
    node_at = function()
      return { id = 'tl', kind = 'timelapse', item = view.tl and view.tl.revs[view.n] or {} }
    end,
    marked = function()
      return {}
    end,
  }
  view.actions = actions(view)
  vim.list_extend(
    view.actions,
    require('perforated.p4vc').actions(ws, nil, function()
      return view.tl and view.tl.depotFile
    end)
  )
  M._last = view
  engine.load(ws, path, function(tl, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if not tl then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '[perforated] ' .. tostring(err) })
      vim.bo[buf].modifiable = false
      return
    end
    view.tl = tl
    local ft = vim.filetype.match({ filename = tl.depotFile })
    if ft then
      vim.bo[buf].filetype = ft
    end
    keys.attach(buf, view.actions, view)
    view.footer = require('perforated.ui.footer').attach(win)
    local start = opts.rev and tl.revs[opts.rev] and opts.rev or tl.head
    view.mode, view.scale = 'single', 'rev'
    M.show(view, start)
    if require('perforated.config').get().timelapse.slider ~= false then
      view.slider = require('perforated.views.slider').attach(view, function(rev)
        go(view, rev)
      end)
    end
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        view.tl = nil -- free the line table
        if view.footer then
          view.footer:close()
        end
        if view.slider then
          view.slider:close()
        end
        if view.dwin and vim.api.nvim_win_is_valid(view.dwin) then
          pcall(vim.api.nvim_win_close, view.dwin, true)
        end
      end,
    })
  end)
  return view
end

--- Time-lapse of the current buffer's file, starting at its revision and cursor line.
---@param buf integer?
function M.open_buf(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local spec = vim.b[buf].perforated_spec
  if spec then
    local wsmod = require('perforated.core.workspace')
    local ws = wsmod.get(vim.b[buf].perforated_ws) or wsmod.connection()
    return M.open(ws, spec, { rev = tonumber(spec:match('#(%d+)$')), line = line })
  end
  local st = require('perforated.buffer').get(buf)
  if not st or not st.rec or not st.rec.depotFile then
    return notify('not a Perforce depot file (or status not known yet)', vim.log.levels.WARN)
  end
  if st.rec.action == 'add' then
    return notify('opened for add: no history yet', vim.log.levels.INFO)
  end
  M.open(st.ws, st.rec.depotFile, { rev = tonumber(st.rec.haveRev), line = line })
end

M._actions = actions -- for the generated help (scripts/gen_doc.lua)

return M
