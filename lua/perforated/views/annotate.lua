--- Annotate (`:P4 annotate`, `b`): a scroll- and cursor-bound split left of the file with the
--- changelist, user and date that last changed each line, coloured by age.
---
--- One p4 call (`annotate -c -i -u -q`: follows branches, carries user and date), one
--- `set_lines`. `~` and `d` fetch the file's history the first time they need it.
--- Lines changed locally (the workspace file differs from its base) show "Not submitted".
--- `<CR>` describes the line's changelist, `~` re-annotates at the revision before that
--- change (`<BS>` goes back), `Q` lists every line from that changelist in the location list.

local base = require('perforated.views.base')
local history = require('perforated.history')

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.annotate')
local AGE_STEPS = 10

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

local function hex_of(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and hl.fg and ('#%06x'):format(hl.fg) or nil
end

local function blend(a, b, t)
  local function ch(h, i)
    return tonumber(h:sub(i, i + 1), 16)
  end
  local out = '#'
  for _, i in ipairs({ 2, 4, 6 }) do
    out = out .. ('%02x'):format(math.floor(ch(a, i) + (ch(b, i) - ch(a, i)) * t + 0.5))
  end
  return out
end

--- Define PerforatedAge1 (oldest) … PerforatedAge10 (newest).
function M.define_age_groups()
  local g = require('perforated.config').get().annotate.gradient
  local old, new = g and g[1] or hex_of('Comment'), g and g[2] or hex_of('DiagnosticWarn')
  for i = 1, AGE_STEPS do
    local name = 'PerforatedAge' .. i
    if old and new then
      vim.api.nvim_set_hl(
        0,
        name,
        { fg = blend(old, new, (i - 1) / (AGE_STEPS - 1)), default = true }
      )
    else
      vim.api.nvim_set_hl(
        0,
        name,
        { link = i > 7 and 'DiagnosticWarn' or (i > 3 and 'Normal' or 'Comment'), default = true }
      )
    end
  end
end

--- Changelist → age step (by rank among the changelists in the file).
---@param cls integer[]
---@return table<integer, integer>
local function age_steps(cls)
  local uniq, seen = {}, {}
  for _, c in ipairs(cls) do
    if not seen[c] then
      seen[c] = true
      uniq[#uniq + 1] = c
    end
  end
  table.sort(uniq)
  local steps = {}
  for i, c in ipairs(uniq) do
    steps[c] = #uniq == 1 and AGE_STEPS or (1 + math.floor((i - 1) * (AGE_STEPS - 1) / (#uniq - 1)))
  end
  return steps
end

--- Buffer line → base line mapping function for the source buffer.
local function mapper(view)
  if not view.local_file then
    return function(l)
      return l
    end
  end
  local st = require('perforated.buffer').get(view.src_buf)
  local hunks = st and st.hunks or {}
  return function(l)
    return base.base_line(hunks, l)
  end
end

-- Highlights come from a decoration provider for the visible rows only (20k extmarks would
-- cost ~40 ms per render).
local row_hl = {} ---@type table<integer, table<integer, string>>  annotate buf → row (0-based) → group
local provider_set = false

local function set_provider()
  if provider_set then
    return
  end
  provider_set = true
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      return row_hl[buf] ~= nil
    end,
    on_line = function(_, _, buf, row)
      local g = row_hl[buf] and row_hl[buf][row]
      if g then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = g,
          ephemeral = true,
        })
      end
    end,
  })
end

--- Render the annotate column for the source buffer's current lines.
function M.render(view)
  if not (vim.api.nvim_buf_is_valid(view.buf) and vim.api.nvim_buf_is_valid(view.src_buf)) then
    return
  end
  set_provider()
  local ann = view.ann
  local cls, meta = ann.cls, ann.meta
  local n = vim.api.nvim_buf_line_count(view.src_buf)
  local map = mapper(view)
  local steps = age_steps(cls)
  local width = require('perforated.config').get().annotate.width
  local lines, hls, line_cl = {}, {}, {}
  local labels = {} -- one formatted label per changelist
  local prev = false
  for l = 1, n do
    local b = map(l)
    local cl = b and cls[b] or nil
    line_cl[l] = cl or false
    if cl ~= prev then
      if cl then
        local label = labels[cl]
        if not label then
          local m = meta[cl] or {}
          label = ('%-8s %-10s %s'):format(cl, (m.user or '?'):sub(1, 10), base.date(m.time))
          labels[cl] = label
        end
        lines[l] = label
        hls[l - 1] = 'PerforatedAge' .. (steps[cl] or 1)
      else
        lines[l] = 'Not submitted'
        hls[l - 1] = 'PerforatedAnnotateLocal'
      end
    else
      lines[l] = ''
    end
    prev = cl
  end
  view.line_cl = line_cl
  row_hl[view.buf] = hls
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  if vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_width(view.win, width)
    -- Line up with the source window. On the first render, restore where the source was
    -- when annotate opened: until now the column was empty, and cursorbind may have pulled
    -- the source's cursor to its line 1.
    if view.src_win and vim.api.nvim_win_is_valid(view.src_win) then
      local src = view.start_view or vim.api.nvim_win_call(view.src_win, vim.fn.winsaveview)
      if view.start_view then
        view.start_view = nil
        vim.api.nvim_win_call(view.src_win, function()
          vim.fn.winrestview(src)
        end)
      end
      vim.api.nvim_win_call(view.win, function()
        vim.fn.winrestview({
          lnum = math.min(src.lnum, #lines),
          col = 0,
          topline = math.min(src.topline, #lines),
        })
      end)
    end
  end
end

--- The node under the cursor in the annotate window (for the action registry).
local function node_at(view)
  local l = vim.api.nvim_win_get_cursor(view.win)[1]
  local cl = view.line_cl and view.line_cl[l]
  if not cl then
    return { id = 'l' .. l, kind = 'annotate_local', item = { lnum = l } }
  end
  local m = view.ann.meta[cl] or { change = cl }
  return {
    id = 'l' .. l,
    kind = 'annotate_line',
    item = { lnum = l, change = tostring(cl), meta = m },
  }
end

local function set_bind(win, on)
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrollbind, vim.wo[win].cursorbind = on, on
  end
end

--- Close the annotate split and restore the source window.
function M.close(view)
  if view.closed then
    return
  end
  view.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, view.aug)
  set_bind(view.src_win, false)
  if vim.api.nvim_win_is_valid(view.src_win) and view.src_wrap ~= nil then
    vim.wo[view.src_win].wrap = view.src_wrap
  end
  if vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  M._views[view.src_win] = nil
  row_hl[view.buf] = nil
end

--- Annotate a spec into the view (source window already shows the right buffer).
local function annotate(view, cb)
  local cfg = require('perforated.config').get().annotate
  history.annotate(view.ws, view.spec, { integrations = cfg.integrations }, function(ann, err)
    if not ann then
      return notify('annotate failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
    view.ann = ann
    -- A depot revision's text loads asynchronously: render once it is in.
    local buf = view.src_buf
    local function ready(k)
      if vim.b[buf].perforated_loaded == false and k < 400 then
        return vim.defer_fn(function()
          ready(k + 1)
        end, 25)
      end
      if view.closed or view.src_buf ~= buf then
        return
      end
      M.render(view)
      if cb then
        cb()
      end
      if vim.api.nvim_win_is_valid(view.win) then
        vim.api.nvim_win_call(view.win, function()
          vim.cmd('syncbind')
        end)
      end
    end
    ready(0)
  end)
end

--- The revision a changelist made to the annotated file or, since `annotate -i` follows
--- branches, to one of the files it was branched from. The history is fetched the first time
--- `~` or `d` needs it (the annotate column itself doesn't).
---@param cb fun(r: perforated.Rev?)
local function rev_of(view, change, cb)
  local function find()
    local hit
    for _, r in ipairs(view.revs or {}) do
      if tonumber(r.change) == change then
        if r.depotFile == view.ann.depotFile then
          return cb(r)
        end
        hit = hit or r
      end
    end
    cb(hit)
  end
  if view.revs and view.revs_of == view.ann.depotFile then
    return find()
  end
  local max = tonumber(require('perforated.config').get().annotate.history_max) or 1000
  history.filelog(view.ws, view.ann.depotFile, { max = max }, function(list, err)
    if not list then
      return notify('filelog failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
    view.revs, view.revs_of = list, view.ann.depotFile
    find()
  end)
end

--- The revision before `r`: the previous revision of its file, or for a branch/copy at #1 the
--- source revision it came from. nil: the file was added in `r`.
---@param r perforated.Rev
---@return string?
local function before(r)
  local n = tonumber(r.rev) or 1
  if n > 1 then
    return r.depotFile .. '#' .. (n - 1)
  end
  if r.from and r.from.file and (r.from.how or ''):match('from$') then
    return r.from.file .. (r.from.erev or '#head')
  end
  return nil
end

--- `~`: annotate the revision before the change that last touched this line.
local function walk_back(view, item)
  local change = tonumber(item.change)
  rev_of(view, change, function(r)
    if not r then
      return notify(
        ('CL %s is not in the history of %s'):format(item.change, view.ann.depotFile),
        vim.log.levels.INFO
      )
    end
    local spec = before(r)
    if not spec then
      return notify(
        ('line added in CL %s (%s#%s): nothing before it'):format(item.change, r.depotFile, r.rev),
        vim.log.levels.INFO
      )
    end
    local lnum = item.lnum
    table.insert(view.stack, {
      spec = view.spec,
      buf = vim.api.nvim_win_get_buf(view.src_win),
      local_file = view.local_file,
      lnum = lnum,
    })
    M.goto_spec(view, spec, lnum)
  end)
end

--- Show another revision in the source window and annotate it.
function M.goto_spec(view, spec, lnum, buf)
  view.spec = spec
  buf = buf or require('perforated.uri').buffer(view.ws, spec)
  view.local_file = view.local_file and buf == view.local_buf
  vim.api.nvim_win_set_buf(view.src_win, buf)
  view.src_buf = buf
  annotate(view, function()
    local n = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, view.src_win, { math.min(lnum or 1, n), 0 })
  end)
  pcall(vim.api.nvim_buf_set_name, view.buf, 'perforated://annotate/' .. spec)
end

local function actions(view)
  local ws = view.ws
  local LINE = { annotate_line = true }
  return {
    {
      id = 'describe',
      desc = 'Describe changelist',
      keys = { '<CR>', 'gd' },
      kinds = LINE,
      footer = 10,
      run = function(items)
        require('perforated.views.describe').open(ws, items[1].change)
      end,
    },
    {
      id = 'view_change',
      desc = 'View changelist',
      keys = { 'K' },
      kinds = LINE,
      footer = 11,
      run = function(items)
        require('perforated.views.change_info').open(ws, { change = items[1].change })
      end,
    },
    {
      id = 'walk_back',
      desc = 'Annotate the revision before this change',
      keys = { '~' },
      kinds = LINE,
      footer = 12,
      run = function(items)
        walk_back(view, items[1])
      end,
    },
    {
      id = 'walk_forward',
      desc = 'Back to the newer revision',
      keys = { '<BS>' },
      when = function()
        return #view.stack > 0
      end,
      footer = 13,
      run = function()
        local top = table.remove(view.stack)
        view.local_file = top.local_file
        M.goto_spec(view, top.spec, top.lnum, top.buf)
      end,
    },
    {
      id = 'diff_change',
      desc = "Diff this change (the file's revision in it vs the one before)",
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = LINE,
      run = function(items)
        local change = tonumber(items[1].change)
        rev_of(view, change, function(r)
          if not r then
            return require('perforated.views.describe').open(ws, items[1].change)
          end
          local prev = before(r)
          require('perforated.revs').diff(
            ws,
            prev and { spec = prev } or { empty = 'added' },
            { spec = r.depotFile .. '#' .. r.rev }
          )
        end)
      end,
    },
    {
      id = 'history',
      desc = 'File history',
      keys = { 'L' },
      p4v = { '<C-t>' },
      run = function()
        require('perforated.views.history').open(
          ws,
          view.ann.depotFile,
          { local_path = view.local_file and view.local_path or nil }
        )
      end,
    },
    {
      id = 'to_loclist',
      desc = 'Lines from this changelist to the location list',
      keys = { 'Q' },
      kinds = LINE,
      run = function(items)
        local cl = tonumber(items[1].change)
        local qf = require('perforated.ui.qf')
        local out = {}
        local name = vim.api.nvim_buf_get_name(view.src_buf)
        for l, c in ipairs(view.line_cl) do
          if c == cl then
            local text = vim.api.nvim_buf_get_lines(view.src_buf, l - 1, l, false)[1] or ''
            out[#out + 1] = qf.item(
              name,
              vim.trim(text),
              { depotFile = view.ann.depotFile, change = tostring(cl), kind = 'annotate_line' },
              l
            )
          end
        end
        qf.set({
          title = ('P4 annotate · CL %s · %s'):format(cl, view.ann.depotFile),
          kind = 'annotate',
          items = out,
          loclist = true,
          win = view.src_win,
        })
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      kinds = LINE,
      run = function(items)
        vim.fn.setreg('"', items[1].change)
        pcall(vim.fn.setreg, '+', items[1].change)
        notify('copied ' .. items[1].change)
      end,
    },
    {
      id = 'swarm',
      desc = 'Open review in Swarm',
      keys = { 'gx' },
      kinds = LINE,
      run = function(items)
        history.swarm(ws, items[1].change)
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      nomenu = true,
      run = function()
        M.close(view)
      end,
    },
    {
      id = 'help',
      desc = 'Help',
      keys = { '?' },
      nomenu = true,
      run = function()
        require('perforated.ui.keys').help(view.actions, 'Annotate')
      end,
    },
    {
      id = 'menu',
      desc = 'Action menu',
      keys = { '.', '<RightMouse>' },
      nomenu = true,
      run = function()
        require('perforated.ui.keys').menu(view.actions, view)
      end,
    },
  }
end

M._views = {} ---@type table<integer, table>  source window → view

--- Annotate the buffer shown in the current window.
---@param buf integer?  0/nil = current
function M.open_buf(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local src_win = vim.api.nvim_get_current_win()
  local existing = M._views[src_win]
  if existing then
    return M.close(existing) -- `b` again toggles it off
  end
  local ws, spec, local_file
  local uri_spec = vim.b[buf].perforated_spec
  if uri_spec then
    local wsmod = require('perforated.core.workspace')
    ws = wsmod.get(vim.b[buf].perforated_ws) or wsmod.connection()
    spec = uri_spec
    if spec:match('@=') then
      return notify('shelved files cannot be annotated', vim.log.levels.WARN)
    end
  else
    local st = require('perforated.buffer').get(buf)
    if not st or not st.rec or not st.rec.depotFile then
      return notify('not a Perforce depot file (or status not known yet)', vim.log.levels.WARN)
    end
    local rec = st.rec
    if rec.action then
      spec = require('perforated.p4').base_spec(rec)
      if not spec then
        return notify(
          'opened for ' .. rec.action .. ': nothing submitted to annotate',
          vim.log.levels.INFO
        )
      end
    else
      spec = rec.depotFile .. '#' .. (rec.haveRev or 'head')
    end
    ws, local_file = st.ws, true
  end
  require('perforated.hl').setup()
  M.define_age_groups()

  local start_view = vim.fn.winsaveview()
  local abuf = vim.api.nvim_create_buf(false, true)
  vim.bo[abuf].bufhidden = 'wipe'
  vim.bo[abuf].buftype = 'nofile'
  vim.bo[abuf].swapfile = false
  vim.b[abuf].perforated_ws = ws.key
  vim.cmd('leftabove vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, abuf)
  pcall(vim.api.nvim_buf_set_name, abuf, 'perforated://annotate/' .. spec)
  vim.api.nvim_win_set_width(win, require('perforated.config').get().annotate.width)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.wrap, wo.winfixwidth, wo.cursorline, wo.list, wo.spell = false, true, true, false, false
  wo.foldenable = false
  vim.bo[abuf].modifiable = false

  local view = {
    ws = ws,
    buf = abuf,
    win = win,
    src_win = src_win,
    src_buf = buf,
    local_buf = local_file and buf or nil,
    local_path = local_file and vim.api.nvim_buf_get_name(buf) or nil,
    local_file = local_file,
    src_wrap = vim.wo[src_win].wrap,
    spec = spec,
    stack = {},
    start_view = start_view,
  }
  view.tree = {
    node_at = function()
      return node_at(view)
    end,
    marked = function()
      return {}
    end,
  }
  vim.wo[src_win].wrap = false
  set_bind(win, true)
  set_bind(src_win, true)
  view.actions = actions(view)
  require('perforated.ui.keys').attach(abuf, view.actions, view)
  M._views[src_win] = view

  view.aug = vim.api.nvim_create_augroup('perforated.annotate.' .. win, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = view.aug,
    pattern = { tostring(win), tostring(src_win) },
    callback = function()
      vim.schedule(function()
        M.close(view)
      end)
    end,
  })
  -- Local edits shift lines: re-map after the buffer's hunks have been recomputed.
  local timer
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave', 'BufWritePost' }, {
    group = view.aug,
    callback = function(ev)
      if ev.buf ~= view.src_buf or not view.ann then
        return
      end
      if timer then
        timer:stop()
      end
      timer = vim.defer_fn(function()
        M.render(view)
      end, 300)
    end,
  })
  vim.bo[abuf].modifiable = true
  vim.api.nvim_buf_set_lines(abuf, 0, -1, false, { 'annotating…' })
  vim.bo[abuf].modifiable = false
  annotate(view)
  M._last = view
  return view
end

--- Annotate a depot revision: open it read-only in a new tab, then annotate.
---@param ws perforated.Workspace
---@param spec string
function M.open_spec(ws, spec)
  local buf = require('perforated.uri').buffer(ws, spec)
  vim.cmd('tab sbuffer ' .. buf)
  return M.open_buf(buf)
end

return M
