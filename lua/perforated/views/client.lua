--- Client view (`:P4`): a p4v-like overview of the workspace in a foldable buffer.
---
---   Header        client · stream · user · server · connection
---   Pending       CLs (default + numbered) → opened files, shelved files
---   Needs attention  stale / unresolved opened files
---   Submitted     recent submits by you (client view)
---   Reconcile     local files not opened (scanned only when expanded; cancellable)
---
--- Always fresh: every open/refresh re-queries in one parallel round (+1 call for shelves),
--- painting a skeleton first. Actions come from one registry (keys, <Space> menu, ? help,
--- footer).

local p4 = require('perforated.p4')
local keys = require('perforated.ui.keys')
local dbg = require('perforated.core.debug')

local M = {}

local views = {} ---@type table<string, table> workspace key → view

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

local function short_date(t)
  t = tonumber(t)
  return t and os.date('%Y-%m-%d', t) or ''
end

-- -------------------------------------------------------------------------------------------
-- Tree building
-- -------------------------------------------------------------------------------------------

---@param view table
---@param rec table fstat/opened record
---@param prefix string id prefix
local function file_node(view, rec, prefix)
  local icons = require('perforated.ui.icons')
  local ws = view.ws
  local path = rec.clientFile
  local shown
  if path and ws.root and path:sub(1, #ws.root + 1) == ws.root .. '/' then
    shown = path:sub(#ws.root + 2)
  else
    shown = rec.depotFile
  end
  local icon, icon_hl = icons.file(shown)
  local text = {
    { ('%-10s'):format(rec.action or ''), 'PerforatedAction' },
    { icon ~= '' and (icon .. ' ') or '', icon_hl },
    { shown, 'PerforatedPath' },
  }
  if rec.haveRev or rec.headRev then
    text[#text + 1] =
      { ('  #%s/#%s'):format(rec.haveRev or '-', rec.headRev or '-'), 'PerforatedRev' }
  end
  if require('perforated.status').is_stale(rec) then
    text[#text + 1] = { '  ' .. icons.glyph('stale') .. ' stale', 'PerforatedStale' }
  end
  if rec.unresolved then
    text[#text + 1] = { '  ' .. icons.glyph('unresolved') .. ' unresolved', 'PerforatedUnresolved' }
  end
  if rec.client and rec.client ~= ws:client() then
    text[#text + 1] = { '  @' .. rec.client, 'PerforatedDim' }
  end
  return {
    id = prefix .. rec.depotFile,
    kind = (rec.client and rec.client ~= ws:client()) and 'other_file' or 'opened_file',
    item = rec,
    text = text,
  }
end

---@param view table
---@param data table
---@return perforated.TreeNode[]
local function build(view, data)
  local ws = view.ws
  local icons = require('perforated.ui.icons')
  local roots = {}

  -- Header
  local info = ws.info or {}
  local conn = ws.conn.state
  roots[#roots + 1] = {
    id = 'hdr',
    kind = 'header',
    text = {
      { 'Client ', 'PerforatedHeader' },
      { ws:client() or '?', 'PerforatedTitle' },
      { info.clientStream and ('  Stream ' .. info.clientStream) or '', 'PerforatedHeader' },
      { '  User ' .. (ws:user() or '?'), 'PerforatedHeader' },
      {
        '  ' .. vim.fn.strcharpart(
          (ws.settings and ws.settings.P4PORT) or info.serverAddress or '',
          0,
          40
        ),
        'PerforatedHeader',
      },
      { '  ' .. conn, conn == 'online' and 'PerforatedDim' or 'PerforatedOffline' },
      { view.scope == 'user' and '  [all my clients]' or '', 'PerforatedBadge' },
    },
  }

  -- Pending: group files by (client, change)
  local by_change = {}
  local order = {}
  local function slot(change, client)
    local key = (client or '') .. '|' .. change
    if not by_change[key] then
      by_change[key] = { change = change, client = client, files = {} }
      order[#order + 1] = key
    end
    return by_change[key]
  end
  local mine = ws:client()
  slot('default', mine)
  for _, c in ipairs(data.pending or {}) do
    local s = slot(c.change, c.client)
    s.rec = c
  end
  for _, f in ipairs(data.opened or {}) do
    table.insert(slot(f.change or 'default', f.client or mine).files, f)
  end
  table.sort(order, function(a, b)
    local x, y = by_change[a], by_change[b]
    if (x.client == mine) ~= (y.client == mine) then
      return x.client == mine
    end
    if x.change == 'default' ~= (y.change == 'default') then
      return x.change == 'default'
    end
    return (tonumber(x.change) or 0) < (tonumber(y.change) or 0)
  end)

  local pending_children = {}
  local attention = {}
  for _, key in ipairs(order) do
    local s = by_change[key]
    local shelved = (data.shelved or {})[s.change] or {}
    if s.change ~= 'default' or #s.files > 0 or s.client == mine then
      table.sort(s.files, function(a, b)
        return (a.clientFile or a.depotFile) < (b.clientFile or b.depotFile)
      end)
      local children = {}
      local nstale, nunres = 0, 0
      for _, f in ipairs(s.files) do
        children[#children + 1] = file_node(view, f, 'f:' .. key .. ':')
        if require('perforated.status').is_stale(f) then
          nstale = nstale + 1
        end
        if f.unresolved then
          nunres = nunres + 1
        end
        if f.client == nil or f.client == mine then
          if require('perforated.status').is_stale(f) or f.unresolved then
            attention[#attention + 1] = f
          end
        end
      end
      if #shelved > 0 then
        local shelf_children = {}
        for _, sf in ipairs(shelved) do
          sf.change = s.change
          shelf_children[#shelf_children + 1] = {
            id = 'sf:' .. s.change .. ':' .. sf.depotFile,
            kind = 'shelved_file',
            item = sf,
            text = {
              { ('%-10s'):format(sf.action or ''), 'PerforatedAction' },
              { sf.depotFile, 'PerforatedPath' },
              { '  #' .. (sf.rev or '?'), 'PerforatedRev' },
            },
          }
        end
        children[#children + 1] = {
          id = 'shelf:' .. key,
          kind = 'shelf',
          item = { change = s.change },
          open = false,
          text = {
            { icons.glyph('shelved') .. ' Shelved (' .. #shelved .. ')', 'PerforatedShelved' },
          },
          children = shelf_children,
        }
      end
      local title
      if s.change == 'default' then
        title = { { 'default', 'PerforatedChangelist' } }
      else
        title = {
          { 'CL ' .. s.change, 'PerforatedChangelist' },
          { '  ' .. first_line(s.rec and s.rec.desc), 'PerforatedPath' },
        }
      end
      title[#title + 1] = { ('  (%d)'):format(#s.files), 'PerforatedDim' }
      if #shelved > 0 then
        title[#title + 1] =
          { '  ' .. icons.glyph('shelved') .. ' ' .. #shelved, 'PerforatedShelved' }
      end
      if nstale > 0 then
        title[#title + 1] = { '  ' .. icons.glyph('stale') .. nstale, 'PerforatedStale' }
      end
      if nunres > 0 then
        title[#title + 1] = { '  ' .. icons.glyph('unresolved') .. nunres, 'PerforatedUnresolved' }
      end
      if s.client and s.client ~= mine then
        title[#title + 1] = { '  @' .. s.client, 'PerforatedDim' }
      end
      pending_children[#pending_children + 1] = {
        id = 'cl:' .. key,
        kind = 'change',
        item = {
          change = s.change,
          client = s.client,
          rec = s.rec,
          files = s.files,
          shelved = shelved,
          mine = s.client == mine,
        },
        open = #s.files <= 30,
        text = title,
        children = (#children > 0) and children or nil,
      }
    end
  end
  roots[#roots + 1] = {
    id = 'sec:pending',
    kind = 'section',
    text = {
      { 'Pending', 'PerforatedSection' },
      { ('  (%d)'):format(#pending_children), 'PerforatedDim' },
    },
    children = pending_children,
  }

  -- Needs attention
  if #attention > 0 then
    local children = {}
    for _, f in ipairs(attention) do
      children[#children + 1] = file_node(view, f, 'a:')
    end
    roots[#roots + 1] = {
      id = 'sec:attention',
      kind = 'section',
      text = {
        { 'Needs attention', 'PerforatedSection' },
        { ('  (%d)'):format(#attention), 'PerforatedBadge' },
      },
      children = children,
    }
  end

  -- Recent submitted (mine)
  local sub_children = {}
  for _, c in ipairs(data.submitted or {}) do
    sub_children[#sub_children + 1] = {
      id = 'sub:' .. c.change,
      kind = 'submitted',
      item = c,
      text = {
        { 'CL ' .. c.change, 'PerforatedChangelist' },
        { '  ' .. short_date(c.time), 'PerforatedDim' },
        { '  ' .. first_line(c.desc), 'PerforatedPath' },
      },
    }
  end
  roots[#roots + 1] = {
    id = 'sec:submitted',
    kind = 'section',
    open = true,
    text = {
      { 'Recent submitted', 'PerforatedSection' },
      { ('  (%d)'):format(#sub_children), 'PerforatedDim' },
    },
    children = sub_children,
  }

  -- Workspace reconcile (lazy)
  local rec_children
  local label
  if view.reconcile.state == 'done' then
    rec_children = {}
    for _, r in ipairs(view.reconcile.recs) do
      local n = file_node(view, r, 'r:')
      n.kind = 'reconcile_file'
      rec_children[#rec_children + 1] = n
    end
    label = ('  (%d)'):format(#rec_children)
  elseif view.reconcile.state == 'running' then
    rec_children = {
      {
        id = 'r:loading',
        kind = 'loading',
        text = { { 'scanning… (x cancels)', 'PerforatedLoading' } },
      },
    }
    label = '  scanning…'
  elseif view.reconcile.state == 'error' then
    rec_children = {
      {
        id = 'r:error',
        kind = 'loading',
        text = { { view.reconcile.err or 'failed', 'ErrorMsg' } },
      },
    }
    label = '  failed'
  else
    rec_children = {
      {
        id = 'r:hint',
        kind = 'loading',
        text = { { 'expand to scan the workspace', 'PerforatedDim' } },
      },
    }
    label = '  (not scanned)'
  end
  roots[#roots + 1] = {
    id = 'sec:reconcile',
    kind = 'section_reconcile',
    open = false,
    text = { { 'Workspace reconcile', 'PerforatedSection' }, { label, 'PerforatedDim' } },
    children = rec_children,
    on_open = function()
      if view.reconcile.state ~= 'running' and view.reconcile.state ~= 'done' then
        M.scan_reconcile(view)
      end
    end,
  }
  return roots
end

-- -------------------------------------------------------------------------------------------
-- Data
-- -------------------------------------------------------------------------------------------

--- Re-query everything (coalesced: one refresh in flight, at most one queued).
---@param view table
function M.refresh(view)
  if view.loading then
    view.again = true
    return
  end
  view.loading = true
  local ws = view.ws
  local t0 = vim.uv.hrtime()
  ws:ensure_info(function()
    local data, left = {}, 3
    local function done()
      left = left - 1
      if left > 0 then
        return
      end
      -- Second round: shelved files, only for CLs that have any.
      local with_shelves = {}
      for _, c in ipairs(data.pending or {}) do
        if c.shelved ~= nil then
          with_shelves[#with_shelves + 1] = c.change
        end
      end
      p4.shelved_files(ws, with_shelves, function(shelved)
        data.shelved = shelved
        view.loading = false
        if vim.api.nvim_buf_is_valid(view.buf) then
          view.data = data
          view.tree:set(build(view, data))
          M.update_footer(view)
          dbg.debug(
            'client',
            'refresh %s: %d pending, %d opened, %d submitted in %.0fms',
            ws.key,
            #(data.pending or {}),
            #(data.opened or {}),
            #(data.submitted or {}),
            (vim.uv.hrtime() - t0) / 1e6
          )
        end
        if view.again then
          view.again = false
          M.refresh(view)
        end
      end)
    end
    p4.pending_changes(ws, function(changes, err)
      data.pending = changes or {}
      data.err = data.err or err
      done()
    end, view.scope)
    if view.scope == 'user' then
      -- Current client with full fstat detail, other clients from `opened -a -u`.
      local recs, others, n = nil, nil, 2
      local function merged()
        n = n - 1
        if n > 0 then
          return
        end
        data.opened = recs or {}
        for _, o in ipairs(others or {}) do
          if o.client ~= ws:client() then
            data.opened[#data.opened + 1] = o
          end
        end
        done()
      end
      p4.fstat_opened(ws, {}, function(r)
        recs = r
        merged()
      end)
      p4.opened_by_user(ws, function(r)
        others = r
        merged()
      end)
    else
      p4.fstat_opened(ws, {}, function(recs)
        data.opened = recs or {}
        done()
      end)
    end
    p4.submitted_changes(ws, {
      user = ws:user(),
      max = require('perforated.config').get().client_view.submitted_limit,
    }, function(changes)
      data.submitted = changes or {}
      done()
    end)
  end)
end

--- Scan for local changes not opened in Perforce (`p4 status`), cancellable.
---@param view table
function M.scan_reconcile(view)
  view.reconcile = { state = 'running', t0 = vim.uv.hrtime() }
  local token = {}
  view.reconcile.token = token
  if view.data then
    view.tree:set(build(view, view.data))
  end
  p4.status(view.ws, nil, function(recs, err)
    if view.reconcile.token ~= token then
      return -- cancelled
    end
    if recs then
      view.reconcile = { state = 'done', recs = recs }
    else
      view.reconcile = { state = 'error', err = err }
    end
    if vim.api.nvim_buf_is_valid(view.buf) and view.data then
      view.tree:set(build(view, view.data))
    end
  end)
end

-- -------------------------------------------------------------------------------------------
-- Actions
-- -------------------------------------------------------------------------------------------

local FILE = { opened_file = true }

---@param items table[]
---@return string[]
local function paths_of(items)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = it.clientFile or it.depotFile
  end
  return out
end

--- Files of a node's item: a CL gives its opened files, a file gives itself.
local function files_of(items)
  local out = {}
  for _, it in ipairs(items) do
    if it.files then
      vim.list_extend(out, it.files)
    else
      out[#out + 1] = it
    end
  end
  return out
end

local function after(view)
  return function()
    M.refresh(view)
  end
end

--- Open a workspace file for diffing: load its buffer, then :P4 diff.
local function diff_file(rec)
  local path = rec.clientFile
  if not path or not path:match('^/') then
    return notify('no local file for ' .. (rec.depotFile or '?'), vim.log.levels.WARN)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local st = require('perforated.buffer').get(buf)
  if not st then
    -- Not attached yet (never opened in this session): attach and wait for its status.
    require('perforated.core.activation').attach(
      buf,
      path,
      require('perforated.gate').lookup(vim.fs.dirname(path))
    )
  end
  vim.wait(3000, function()
    local s = require('perforated.buffer').get(buf)
    return s ~= nil and s.rec ~= nil
  end, 10)
  require('perforated.diff.view').open(buf)
end

---@param view table
---@return perforated.Action[]
local function actions(view)
  local ws = view.ws
  local tree_node_expand = function(_, ctx)
    local node = ctx.node
    if node and node.children then
      view.tree:toggle(node)
    else
      keys.menu(view.actions, view)
    end
  end
  return {
    -- Navigation (not in the <Space> menu)
    {
      id = 'expand',
      desc = 'Expand / toggle',
      keys = { 'l', '<Tab>', '<CR>' },
      nomenu = true,
      run = tree_node_expand,
    },
    {
      id = 'collapse',
      desc = 'Collapse',
      keys = { 'h' },
      nomenu = true,
      run = function()
        view.tree:collapse_at_cursor()
      end,
    },
    {
      id = 'next_section',
      desc = 'Next section',
      keys = { ']]' },
      nomenu = true,
      run = function()
        view.tree:jump_section(true)
      end,
    },
    {
      id = 'prev_section',
      desc = 'Previous section',
      keys = { '[[' },
      nomenu = true,
      run = function()
        view.tree:jump_section(false)
      end,
    },
    {
      id = 'goto_pending',
      desc = 'Go to Pending',
      keys = { 'g1' },
      p4v = { '<C-1>' },
      nomenu = true,
      run = function()
        local row = view.tree:row_of('sec:pending')
        if row then
          vim.api.nvim_win_set_cursor(0, { row, 0 })
        end
      end,
    },
    {
      id = 'goto_submitted',
      desc = 'Go to Submitted',
      keys = { 'g2' },
      p4v = { '<C-2>' },
      nomenu = true,
      run = function()
        local row = view.tree:row_of('sec:submitted')
        if row then
          vim.api.nvim_win_set_cursor(0, { row, 0 })
        end
      end,
    },
    {
      id = 'refresh',
      desc = 'Refresh',
      keys = { 'gr' },
      nomenu = true,
      run = function()
        M.refresh(view)
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      p4v = { '<C-w>' },
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
        keys.help(view.actions, 'Perforce')
      end,
    },
    {
      id = 'menu',
      desc = 'Action menu',
      keys = { '<Space>', '<RightMouse>' },
      nomenu = true,
      run = function()
        keys.menu(view.actions, view)
      end,
    },
    {
      id = 'mark',
      desc = 'Mark / unmark',
      keys = { 'm' },
      nomenu = true,
      run = function()
        view.tree:mark()
        vim.cmd('normal! j')
      end,
    },
    {
      id = 'unmark_all',
      desc = 'Clear marks',
      keys = { 'u' },
      nomenu = true,
      run = function()
        view.tree:clear_marks()
      end,
    },
    {
      id = 'scope',
      desc = 'Toggle scope: this client / all my clients',
      keys = { 'A' },
      nomenu = true,
      run = function()
        view.scope = view.scope == 'user' and 'client' or 'user'
        M.refresh(view)
      end,
    },

    -- Files
    {
      id = 'diff',
      desc = 'Diff',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = { opened_file = true, shelved_file = true },
      footer = 10,
      run = function(items)
        local it = items[1]
        if it.depotFile and it.change and not it.clientFile then
          -- shelved file: base revision vs shelved content
          local base = it.rev and (it.depotFile .. '#' .. it.rev) or nil
          require('perforated.diff.view').pair(
            ws,
            base and { spec = base } or { empty = 'new file' },
            { spec = it.depotFile .. '@=' .. it.change },
            { spec = base, path = it.depotFile }
          )
        else
          diff_file(it)
        end
      end,
    },
    {
      id = 'diff_all',
      desc = 'Diff all files',
      keys = { 'D' },
      kinds = { change = true, submitted = true, shelf = true },
      footer = 11,
      run = function(items)
        require('perforated.diff.tab').open_change(ws, items[1])
      end,
    },
    {
      id = 'open',
      desc = 'Open file',
      keys = { 'o' },
      kinds = FILE,
      footer = 20,
      run = function(items)
        M.open_file(view, items[1].clientFile)
      end,
    },
    {
      id = 'revert',
      desc = 'Revert',
      keys = { 'x' },
      p4v = { '<C-r>' },
      kinds = { opened_file = true, change = true },
      multi = true,
      footer = 30,
      when = function(item)
        return item.files == nil or #item.files > 0
      end,
      run = function(items)
        local files = files_of(items)
        local what = #files == 1 and (files[1].clientFile or files[1].depotFile)
          or (#files .. ' files')
        if
          vim.fn.confirm(
            ('Revert %s? Local changes will be lost.'):format(what),
            '&Revert\n&Cancel',
            2
          ) ~= 1
        then
          return
        end
        require('perforated.checkout').revert(ws, paths_of(files), false, after(view))
        view.tree.marks = {}
      end,
    },
    {
      id = 'revert_unchanged',
      desc = 'Revert unchanged',
      keys = { 'X' },
      kinds = { opened_file = true, change = true },
      multi = true,
      run = function(items)
        require('perforated.checkout').revert(ws, paths_of(files_of(items)), true, after(view))
        view.tree.marks = {}
      end,
    },
    {
      id = 'move',
      desc = 'Move to changelist',
      keys = { 'M' },
      kinds = FILE,
      multi = true,
      footer = 40,
      run = function(items)
        require('perforated.checkout').pick_change(ws, function(cl)
          if not cl then
            return
          end
          p4.reopen(ws, paths_of(items), cl, function(res)
            if #res.errors > 0 then
              notify('move failed: ' .. res.errors[1], vim.log.levels.ERROR)
            else
              notify(
                ('moved %d file(s) to %s'):format(
                  #res.records,
                  cl == 'default' and 'default' or ('CL ' .. cl)
                )
              )
            end
            view.tree.marks = {}
            M.refresh(view)
          end)
        end)
      end,
    },
    {
      id = 'yank',
      desc = 'Copy depot path / CL number',
      keys = { 'y' },
      p4v = { '<C-S-c>' },
      kinds = {
        opened_file = true,
        shelved_file = true,
        reconcile_file = true,
        change = true,
        submitted = true,
      },
      run = function(items)
        local it = items[1]
        local text = it.depotFile or it.change
        vim.fn.setreg('"', text)
        pcall(vim.fn.setreg, '+', text)
        notify('copied ' .. text)
      end,
    },

    -- Changelists
    {
      id = 'new_change',
      desc = 'New changelist',
      keys = { 'c' },
      p4v = { '<C-n>' },
      footer = 50,
      run = function()
        require('perforated.views.change_editor').new(ws, { on_done = after(view) })
      end,
    },
    {
      id = 'edit_description',
      desc = 'Edit description',
      keys = { 'C' },
      kinds = { change = true, submitted = true },
      footer = 51,
      when = function(item)
        return item.change ~= 'default' and (item.mine ~= false)
      end,
      run = function(items, ctx)
        require('perforated.views.change_editor').edit(ws, items[1].change, {
          submitted = ctx.node and ctx.node.kind == 'submitted',
          on_done = after(view),
        })
      end,
    },

    -- Reconcile
    {
      id = 'reconcile_apply',
      desc = 'Open for add / edit / delete as found',
      keys = { 'a' },
      kinds = { reconcile_file = true },
      multi = true,
      footer = 10,
      run = function(items)
        local by = { add = {}, edit = {}, delete = {} }
        for _, it in ipairs(items) do
          table.insert(by[it.action] or by.edit, it.clientFile)
        end
        local co = require('perforated.checkout')
        if #by.add > 0 then
          co.add(ws, by.add, ws.sticky_cl, after(view))
        end
        if #by.edit > 0 then
          co.edit(ws, by.edit, ws.sticky_cl, after(view))
        end
        if #by.delete > 0 then
          ws:run({ 'delete' }, { globals = { '-x', '-' }, stdin = by.delete }, after(view))
        end
        view.reconcile = { state = 'idle' }
      end,
    },
    {
      id = 'reconcile_cancel',
      desc = 'Cancel scan',
      keys = { 'x' },
      kinds = { loading = true, section_reconcile = true },
      nomenu = true,
      when = function()
        return view.reconcile.state == 'running'
      end,
      run = function()
        view.reconcile = { state = 'idle' }
        view.tree:set(build(view, view.data or {}))
      end,
    },

    -- Quickfix
    {
      id = 'to_qf',
      desc = 'Send to quickfix',
      keys = { 'Q' },
      multi = true,
      footer = 60,
      run = function(items, ctx)
        M.to_qf(view, items, ctx, false)
      end,
    },
    {
      id = 'to_loclist',
      desc = 'Send to location list',
      keys = { 'gQ' },
      multi = true,
      run = function(items, ctx)
        M.to_qf(view, items, ctx, true)
      end,
    },
  }
end

--- Send nodes (files, CLs, sections) to the quickfix / location list.
function M.to_qf(view, _, ctx, loclist)
  local qf = require('perforated.ui.qf')
  local recs = {}
  local function add(node)
    if node.item and (node.item.clientFile or node.item.depotFile) and not node.children then
      recs[#recs + 1] = node.item
    end
    for _, ch in ipairs(node.children or {}) do
      add(ch)
    end
  end
  for _, n in ipairs(ctx.nodes) do
    add(n)
  end
  local qitems = {}
  for _, r in ipairs(recs) do
    if r.clientFile and r.clientFile:match('^/') then
      qitems[#qitems + 1] = qf.item(
        r.clientFile,
        ('%-10s %s'):format(r.action or '', r.change and ('CL ' .. r.change) or ''),
        {
          depotFile = r.depotFile,
          change = r.change,
          action = r.action,
          kind = 'client_view',
        }
      )
    else
      local spec = r.change and (r.depotFile .. '@=' .. r.change) or r.depotFile
      qitems[#qitems + 1] = qf.item(
        'perforated://' .. spec,
        ('%-10s shelved in CL %s'):format(r.action or '', r.change or '?'),
        {
          depotFile = r.depotFile,
          change = r.change,
          kind = 'shelved',
        }
      )
    end
  end
  vim.cmd('wincmd p')
  qf.set({
    title = 'P4 · ' .. (view.ws:client() or view.ws.key),
    kind = 'client_view',
    items = qitems,
    loclist = loclist,
  })
end

-- -------------------------------------------------------------------------------------------
-- Window management
-- -------------------------------------------------------------------------------------------

function M.update_footer(view)
  if view.footer then
    view.footer:set(keys.footer(view.actions, view.tree:node_at()))
  end
end

--- Open a file from the view: in the window the user came from (previous tab when the view
--- has its own tab), else a new tab.
function M.open_file(view, path)
  if not path or not path:match('^/') then
    return notify('no local file', vim.log.levels.WARN)
  end
  local origin = view.origin_win
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  else
    vim.cmd('tabnew ' .. vim.fn.fnameescape(path))
  end
end

function M.close(view)
  if view.footer then
    view.footer:close()
  end
  local win = vim.fn.bufwinid(view.buf)
  if view.kind == 'tab' and win ~= -1 and #vim.api.nvim_list_tabpages() > 1 then
    local tab = vim.api.nvim_win_get_tabpage(win)
    pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
  elseif win ~= -1 and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, win, true)
  else
    vim.cmd('enew')
  end
end

---@param buf integer
---@param kind 'tab'|'float'|'split'
---@return integer win
local function show(buf, kind)
  if kind == 'float' then
    local w = math.floor(vim.o.columns * 0.8)
    local h = math.floor(vim.o.lines * 0.8)
    return vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      row = math.floor((vim.o.lines - h) / 2) - 1,
      col = math.floor((vim.o.columns - w) / 2),
      width = w,
      height = h,
      border = 'rounded',
      title = ' Perforce ',
      title_pos = 'center',
    })
  elseif kind == 'split' then
    vim.cmd('topleft vsplit')
    vim.api.nvim_win_set_width(0, math.max(60, math.floor(vim.o.columns * 0.35)))
  else
    vim.cmd('tabnew')
    local scratch = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)
    if scratch ~= buf then
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end
    return vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(0, buf)
  return vim.api.nvim_get_current_win()
end

--- Open (or focus) the client view of a workspace.
---@param ws perforated.Workspace
---@param opts { kind: ('tab'|'float'|'split')? }?
function M.open(ws, opts)
  local kind = (opts and opts.kind) or require('perforated.config').get().client_view.kind
  local origin = vim.api.nvim_get_current_win()
  local view = views[ws.key]
  if view and vim.api.nvim_buf_is_valid(view.buf) then
    local win = vim.fn.bufwinid(view.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      view.kind = kind
      view.win = show(view.buf, kind)
      view.footer = require('perforated.ui.footer').attach(view.win)
    end
    view.origin_win = origin
    M.refresh(view)
    return view
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'perforated://client/' .. (ws:client() or ws.key))
  require('perforated.hl').setup()
  view = {
    ws = ws,
    buf = buf,
    kind = kind,
    scope = 'client',
    origin_win = origin,
    reconcile = { state = 'idle' },
  }
  views[ws.key] = view
  view.tree = require('perforated.ui.tree').new(buf)
  view.actions = actions(view)
  view.win = show(buf, kind)
  vim.wo[view.win].cursorline = true
  vim.wo[view.win].wrap = false
  vim.wo[view.win].number = false
  vim.wo[view.win].relativenumber = false
  vim.wo[view.win].signcolumn = 'no'
  vim.wo[view.win].foldcolumn = '0'
  view.footer = require('perforated.ui.footer').attach(view.win)
  keys.attach(buf, view.actions, view)

  -- Skeleton first (instant), then data.
  view.tree:set({
    {
      id = 'hdr',
      kind = 'header',
      text = { { 'Client ', 'PerforatedHeader' }, { ws:client() or '…', 'PerforatedTitle' } },
    },
    { id = 'sec:loading', kind = 'loading', text = { { 'loading…', 'PerforatedLoading' } } },
  })
  M.update_footer(view)

  local group = vim.api.nvim_create_augroup('perforated.client.' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = buf,
    callback = function()
      M.update_footer(view)
    end,
  })
  -- Changes made elsewhere (check-out, revert, …) refresh a visible view.
  local pending_refresh = false
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'PerforatedChanged',
    callback = function(ev)
      if (ev.data or {}).ws ~= ws.key or vim.fn.bufwinid(buf) == -1 or pending_refresh then
        return
      end
      pending_refresh = true
      vim.defer_fn(function()
        pending_refresh = false
        M.refresh(view)
      end, 150)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      views[ws.key] = nil
      if view.footer then
        view.footer:close()
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  M.refresh(view)
  -- FileType last and after the first paint: user/plugin FileType handlers and the runtime
  -- search for ftplugin/syntax files can take several ms (`:h lua-plugin`: "as late as
  -- possible").
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].filetype = 'perforated'
    end
  end)
  return view
end

--- Test helper: the view of a workspace.
function M._get(ws_key)
  return views[ws_key]
end

return M
