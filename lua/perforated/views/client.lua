--- Client view (`:P4`): a p4v-like overview of the workspace in a foldable buffer.
---
---   Header        client · stream · user · server · connection
---   Pending       CLs (default + numbered) → opened files, shelved files
---   Needs attention  stale / unresolved opened files
---   Submitted     recent submits by you (client view)
---   Reconcile     local files not opened (scanned only when expanded; cancellable)
---
--- Always fresh: every open/refresh re-queries in one parallel round (+1 call for shelves),
--- painting a skeleton first. Actions come from one registry (keys, `.` menu, ? help,
--- footer).

local p4 = require('perforated.p4')
local cls = require('perforated.changelists')
local keys = require('perforated.ui.keys')
local dbg = require('perforated.core.debug')

local M = {}

local views = {} ---@type table<string, table> workspace key → view

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
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
  -- ● changed / dimmed unchanged (opened files of this client; see modified.lua)
  local d, changed = view.data, nil
  if d and d.modified ~= nil then
    changed = require('perforated.modified').is_changed(ws, rec, d.modified, d.overlay)
  end
  local marker, row_hl = require('perforated.modified').marker(changed)
  local stale = require('perforated.status').is_stale(rec)
  -- Unresolved (needs action now) outranks stale; both colour the ● and the path.
  local state_hl = rec.unresolved and 'PerforatedUnresolved' or (stale and 'PerforatedStale')
  if marker and state_hl and vim.trim(marker[1]) ~= '' then
    marker = { marker[1], state_hl }
  end
  local text = {
    marker or { '' },
    {
      -- In "Needs attention" the changelist isn't visible from the tree: show it.
      prefix == 'a:' and ('%-18s'):format(
        ('%s (%s)'):format(rec.action or '', rec.change or 'default')
      ) or ('%-10s'):format(rec.action or ''),
      row_hl == 'PerforatedUnchanged' and row_hl or 'PerforatedAction',
    },
    { icon ~= '' and (icon .. ' ') or '', row_hl == 'PerforatedUnchanged' and row_hl or icon_hl },
    -- A stale or unresolved file's path takes the colour of its badge, whatever its changed
    -- state.
    { shown, state_hl or row_hl or 'PerforatedPath' },
  }
  if rec.haveRev or rec.headRev then
    text[#text + 1] =
      { ('  #%s/#%s'):format(rec.haveRev or '-', rec.headRev or '-'), 'PerforatedRev' }
  end
  if stale then
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

  -- Sync CL: the newest changelist the workspace has
  local have = data.have
  if have then
    local t = tonumber(have.time)
    roots[#roots + 1] = {
      id = 'have',
      kind = 'have_cl',
      item = have,
      text = {
        { '    Sync CL: ', 'PerforatedSection' },
        { have.change, 'PerforatedChangelist' },
        { '  ' .. first_line(have.desc), 'PerforatedPath' },
        {
          ('  %s %s'):format(have.user or '', t and os.date('%Y-%m-%d', t) or ''),
          'PerforatedDim',
        },
      },
    }
  else
    roots[#roots + 1] = {
      id = 'have',
      kind = 'header',
      text = {
        { '    Sync CL: ', 'PerforatedSection' },
        have == false and { 'nothing synced', 'PerforatedDim' }
          or { 'loading…', 'PerforatedLoading' },
      },
    }
  end

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
    -- Default first, then the newest changelists.
    return (tonumber(x.change) or 0) > (tonumber(y.change) or 0)
  end)

  local is_stale = require('perforated.status').is_stale
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
        local stale = is_stale(f)
        if stale then
          nstale = nstale + 1
        end
        if f.unresolved then
          nunres = nunres + 1
        end
        if f.client == nil or f.client == mine then
          if stale or f.unresolved then
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
              { ('%-10s'):format(sf.action or ''), 'PerforatedShelvedFile' },
              { sf.depotFile, 'PerforatedShelvedFile' },
              { '  #' .. (sf.rev or '?'), 'PerforatedRev' },
            },
          }
        end
        children[#children + 1] = {
          id = 'shelf:' .. key,
          kind = 'shelf',
          item = { change = s.change, shelved = shelved },
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
      title[#title + 1] =
        { ('  (%d)'):format(#s.files), #s.files > 0 and 'PerforatedCount' or 'PerforatedDim' }
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
  local npending = #pending_children
  if not (data.pending and data.opened) then
    -- Still loading (first refresh): no half-built changelists, nothing needs attention yet.
    pending_children, attention, npending =
      {
        { id = 'pending:loading', kind = 'loading', text = { { 'loading…', 'PerforatedLoading' } } },
      }, {}, 0
  end
  if data.err and data.err ~= '' then
    -- A failed query must not look like an empty workspace.
    table.insert(pending_children, 1, {
      id = 'err',
      kind = 'loading',
      text = { { 'refresh failed: ' .. data.err, 'ErrorMsg' } },
    })
  end
  roots[#roots + 1] = {
    id = 'sec:pending',
    kind = 'section',
    text = {
      { 'Pending', 'PerforatedSection' },
      { ('  (%d)'):format(npending), 'PerforatedDim' },
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

  -- Workspace reconcile (lazy)
  local scope = M.reconcile_scope(view.ws)
  local rec_children
  local label
  if view.reconcile.state == 'done' then
    rec_children = {}
    for _, r in ipairs(view.reconcile.recs) do
      local n = file_node(view, r, 'r:')
      n.kind = 'reconcile_file'
      rec_children[#rec_children + 1] = n
    end
    label = ('  (%d · r rescans)'):format(#rec_children)
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
        text = {
          {
            'expand to scan '
              .. (#scope > 0 and 'these paths' or 'the whole client')
              .. ' · p sets the paths',
            'PerforatedDim',
          },
        },
      },
    }
    label = '  (not scanned)'
  end
  roots[#roots + 1] = {
    id = 'sec:reconcile',
    kind = 'section_reconcile',
    open = false,
    text = {
      { 'Workspace reconcile', 'PerforatedSection' },
      { #scope > 0 and ('  · ' .. table.concat(scope, ' ')) or '', 'PerforatedHeader' },
      { label, 'PerforatedDim' },
    },
    children = rec_children,
    on_open = function()
      if view.reconcile.state ~= 'running' and view.reconcile.state ~= 'done' then
        M.scan_reconcile(view)
      end
    end,
  }
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
  local nsub = #sub_children
  if not data.submitted then
    sub_children = {
      { id = 'sub:loading', kind = 'loading', text = { { 'loading…', 'PerforatedLoading' } } },
    }
  end
  roots[#roots + 1] = {
    id = 'sec:submitted',
    kind = 'section',
    open = true,
    text = {
      { 'Recent submitted', 'PerforatedSection' },
      { ('  (%d)'):format(nsub), 'PerforatedDim' },
    },
    children = sub_children,
  }

  -- A blank line before each section.
  local spaced = {}
  for _, n in ipairs(roots) do
    if (n.kind == 'section' or n.kind == 'section_reconcile') and #spaced > 0 then
      spaced[#spaced + 1] = { id = 'sp:' .. n.id, kind = 'spacer', text = { { '' } } }
    end
    spaced[#spaced + 1] = n
  end
  roots = spaced
  return roots
end

-- -------------------------------------------------------------------------------------------
-- Data
-- -------------------------------------------------------------------------------------------

--- Re-query everything (coalesced: one refresh in flight, at most one queued). Each section
--- is drawn as soon as its own query answers, so a slow query (the Sync CL's
--- `changes -m1 #have` on a large workspace) never holds back the rest. Until then
--- a section shows what the previous refresh found, or "loading…" the first time.
---@param view table
function M.refresh(view)
  if not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  if view.loading then
    view.again = true
    return
  end
  view.loading = true
  local ws = view.ws
  local t0 = vim.uv.hrtime()
  local prev = view.data or {}
  ws:ensure_info(function()
    local data, got, left = {}, {}, 6
    local function set(k, v)
      data[k], got[k] = v, true
    end
    local function field(k)
      if got[k] then
        return data[k]
      end
      return prev[k]
    end
    local function render()
      if not vim.api.nvim_buf_is_valid(view.buf) then
        return
      end
      local shown = { err = data.err }
      -- Pending CLs and their files are shown together, never one new and one old.
      if got.pending and got.opened then
        shown.pending, shown.opened = data.pending, data.opened
      else
        shown.pending, shown.opened = prev.pending, prev.opened
      end
      shown.have, shown.submitted = field('have'), field('submitted')
      shown.shelved, shown.modified = field('shelved'), field('modified')
      shown.overlay = require('perforated.modified').overlay(ws)
      view.data = shown
      local t1 = vim.uv.hrtime()
      view.tree:set(build(view, shown))
      dbg.timing('client view: render', (vim.uv.hrtime() - t1) / 1e6)
      M.update_footer(view)
    end
    local queued = false
    local function done()
      left = left - 1
      if left > 0 then
        -- Partial result: draw it on the next tick (several answers in one tick draw once).
        if not queued then
          queued = true
          vim.schedule(function()
            queued = false
            if view.loading then
              render()
            end
          end)
        end
        return
      end
      view.loading = false
      render()
      dbg.timing('client view: refresh', (vim.uv.hrtime() - t0) / 1e6)
      dbg.debug(
        'client',
        'refresh %s: %d pending, %d opened, %d submitted in %.0fms',
        ws.key,
        #(data.pending or {}),
        #(data.opened or {}),
        #(data.submitted or {}),
        (vim.uv.hrtime() - t0) / 1e6
      )
      if view.again then
        view.again = false
        M.refresh(view)
      end
    end
    p4.pending_changes(ws, function(changes, err)
      set('pending', changes or {})
      data.err = data.err or err
      done()
      -- Shelved files, only for CLs that have any.
      local with_shelves = {}
      for _, c in ipairs(changes or {}) do
        if c.shelved ~= nil then
          with_shelves[#with_shelves + 1] = c.change
        end
      end
      cls.shelved_files(ws, with_shelves, function(shelved)
        set('shelved', shelved)
        done()
      end)
    end, view.scope)
    local function failed(res)
      data.err = data.err or res.errors[1] or vim.trim(res.stderr or '')
    end
    cls.have_change(ws, function(c)
      set('have', c or false)
      done()
    end)
    require('perforated.modified').query(ws, nil, function(changed)
      set('modified', changed or false) -- false: unknown (no markers)
      done()
    end)
    if view.scope == 'user' then
      -- Current client with full fstat detail, other clients from `opened -a -u`.
      local recs, others, n = nil, nil, 2
      local function merged()
        n = n - 1
        if n > 0 then
          return
        end
        local opened = recs or {}
        for _, o in ipairs(others or {}) do
          if o.client ~= ws:client() then
            opened[#opened + 1] = o
          end
        end
        set('opened', opened)
        done()
      end
      p4.fstat_opened(ws, {}, function(r, res)
        recs = r
        if not r then
          failed(res)
        end
        merged()
      end)
      cls.opened_by_user(ws, function(r)
        others = r
        merged()
      end)
    else
      p4.fstat_opened(ws, {}, function(recs, res)
        set('opened', recs or {})
        if not recs then
          failed(res)
        end
        done()
      end)
    end
    cls.submitted_changes(ws, {
      user = ws:user(),
      anywhere = true, -- all of the user's submits, not only those in this client's view
      max = require('perforated.config').get().client_view.submitted_limit,
    }, function(changes, err)
      set('submitted', changes or {})
      data.err = data.err or err
      done()
    end)
  end)
end

--- Scan for local changes not opened in Perforce (`p4 status`), cancellable.
---@param view table
--- The reconcile scope: the session's choice (`p` in the view), else
--- `client_view.reconcile.paths` (a list, or a function(ws) returning one). Entries are paths
--- relative to the client root, local paths or depot paths; empty = the whole client.
---@param ws perforated.Workspace
---@return string[] entries  as configured (for display)
function M.reconcile_scope(ws)
  if ws.reconcile_scope then
    return ws.reconcile_scope
  end
  local cfg = (require('perforated.config').get().client_view.reconcile or {}).paths
  if type(cfg) == 'function' then
    cfg = cfg(ws)
  end
  return type(cfg) == 'table' and cfg or {}
end

--- Scope entries → `p4 status` arguments (nil = the whole client).
---@param ws perforated.Workspace
---@param entries string[]
---@return string[]?
function M.reconcile_args(ws, entries)
  if #entries == 0 then
    return nil
  end
  local out = {}
  for _, e in ipairs(entries) do
    e = vim.trim(e)
    if e ~= '' then
      if not e:match('^//') and not e:match('^/') and not e:match('^~') then
        e = (ws.root or ws:cwd()) .. '/' .. e
      elseif e:match('^~') then
        e = vim.fn.expand(e)
      end
      e = e:gsub('/+$', '')
      if not e:find('...', 1, true) and not e:find('*', 1, true) then
        e = e .. '/...'
      end
      out[#out + 1] = e
    end
  end
  return #out > 0 and out or nil
end

function M.scan_reconcile(view)
  if view.reconcile.job then
    require('perforated.jobs').cancel(view.reconcile.job)
  end
  local jobs = require('perforated.jobs')
  local entries = M.reconcile_scope(view.ws)
  local label = #entries > 0 and table.concat(entries, ' ') or 'workspace'
  local job, run_opts = jobs.start(view.ws, 'reconcile ' .. label)
  view.reconcile = { state = 'running', t0 = vim.uv.hrtime(), job = job }
  if view.data then
    view.tree:set(build(view, view.data))
  end
  cls.status(view.ws, M.reconcile_args(view.ws, entries), function(recs, err)
    if view.reconcile.job ~= job then
      jobs.finish(job, 'superseded', false)
      return
    end
    if recs then
      jobs.finish(job, ('%d file(s) to reconcile'):format(#recs))
      view.reconcile = { state = 'done', recs = recs }
    elseif err == 'cancelled' then
      jobs.finish(job, 'stopped', true)
      view.reconcile = { state = 'idle' }
    else
      jobs.finish(job, tostring(err), true)
      view.reconcile = { state = 'error', err = err }
    end
    if vim.api.nvim_buf_is_valid(view.buf) and view.data then
      view.tree:set(build(view, view.data))
    end
  end, run_opts)
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

--- Shelf / shelved-file (or changelist) nodes grouped by changelist: change → depot files, or false for the
--- whole shelf.
---@param nodes perforated.TreeNode[]
---@return table<string, string[]|false>
local function shelved_by_change(nodes)
  local out = {}
  for _, n in ipairs(nodes) do
    local change = n.item.change
    if n.kind == 'shelf' or n.kind == 'change' then
      out[change] = false
    elseif out[change] ~= false then
      out[change] = out[change] or {}
      table.insert(out[change], n.item.depotFile)
    end
  end
  return out
end

--- Open a workspace file for diffing: load its buffer, then :P4 diff (against `rev`, default
--- the have revision).
local function diff_file(rec, rev)
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
  require('perforated.diff.view').open(buf, rev)
end

--- A workspace file with depot history (not another client's file, not a new add).
local function local_with_history(item)
  return item.haveRev ~= nil and (item.clientFile or ''):match('^/[^/]') ~= nil
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
    -- Navigation (not in the action menu)
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
      p4v = { '<F5>' }, -- P4V's refresh key
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
      keys = { '.', '<RightMouse>' },
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
    {
      id = 'switch_client',
      desc = 'Switch client (pick one of your clients)',
      keys = { 'W' },
      run = function()
        M.switch_client(view)
      end,
    },

    -- Files
    {
      id = 'diff',
      desc = 'Diff against have revision',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = { opened_file = true },
      footer = 10,
      run = function(items)
        diff_file(items[1])
      end,
    },
    {
      id = 'diff_revision',
      desc = 'Diff against revision…',
      keys = { 'gD' },
      kinds = { opened_file = true },
      when = local_with_history,
      run = function(items)
        local it = items[1]
        require('perforated.picker.sources').revision(
          ws,
          it,
          'Diff ' .. vim.fn.fnamemodify(it.clientFile, ':t') .. ' against',
          function(r)
            diff_file(it, '#' .. r.rev)
          end
        )
      end,
    },
    {
      id = 'diff_shelved',
      desc = 'Diff shelved vs base revision',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = { shelved_file = true },
      footer = 10,
      run = function(items)
        local it = items[1]
        local base = it.rev and (it.depotFile .. '#' .. it.rev) or nil
        local left = base and { spec = base, label = 'base' } or { empty = 'new file' }
        local right = { spec = it.depotFile .. '@=' .. it.change }
        require('perforated.same').or_open(ws, left, right, function()
          require('perforated.diff.view').pair(
            ws,
            left,
            right,
            { spec = base, path = it.depotFile }
          )
        end)
      end,
    },
    -- M4: shelve, submit, resolve, sync, integrate
    {
      id = 'shelve',
      desc = 'Shelve',
      keys = { 's' },
      kinds = { opened_file = true, change = true },
      multi = true,
      footer = 40,
      when = function(item)
        return item.change ~= 'default'
          and (item.files == nil or #item.files > 0)
          and item.mine ~= false
      end,
      run = function(items, ctx)
        local ops = require('perforated.ops')
        if ctx.nodes[1].kind == 'change' and #ctx.nodes == 1 then
          return ops.shelve(ws, items[1].change, nil)
        end
        local by_cl = {}
        for _, f in ipairs(files_of(items)) do
          local cl = f.change or 'default'
          by_cl[cl] = by_cl[cl] or {}
          table.insert(by_cl[cl], f.clientFile or f.depotFile)
        end
        for cl, paths in pairs(by_cl) do
          ops.shelve(ws, cl, paths)
        end
        view.tree.marks = {}
      end,
    },
    {
      id = 'unshelve',
      desc = 'Unshelve',
      keys = { 'S' },
      kinds = { shelf = true, shelved_file = true, change = true },
      multi = true,
      footer = 41,
      when = function(item, node)
        return node.kind ~= 'change' or #(item.shelved or {}) > 0
      end,
      run = function(_, ctx)
        local ops = require('perforated.ops')
        for change, files in pairs(shelved_by_change(ctx.nodes)) do
          ops.unshelve(ws, change, files or nil, nil)
        end
        view.tree.marks = {}
      end,
    },
    {
      id = 'delete_shelved',
      desc = 'Delete shelved files',
      keys = { '<Del>' },
      kinds = { shelf = true, shelved_file = true },
      multi = true,
      run = function(_, ctx)
        local ops = require('perforated.ops')
        for change, files in pairs(shelved_by_change(ctx.nodes)) do
          ops.delete_shelved(ws, change, files or nil)
        end
        view.tree.marks = {}
      end,
    },
    {
      -- On a changelist `<Del>` deletes the changelist itself.
      id = 'delete_shelved_change',
      desc = 'Delete shelved files',
      keys = { 'g<Del>' },
      kinds = { change = true },
      multi = true,
      when = function(item)
        return #(item.shelved or {}) > 0 and item.mine ~= false
      end,
      run = function(_, ctx)
        local ops = require('perforated.ops')
        for change in pairs(shelved_by_change(ctx.nodes)) do
          ops.delete_shelved(ws, change, nil)
        end
        view.tree.marks = {}
      end,
    },
    {
      id = 'submit',
      desc = 'Submit',
      keys = { 'P' },
      p4v = { '<C-s>' },
      kinds = { change = true },
      footer = 42,
      when = function(item)
        return item.mine ~= false and #(item.files or {}) > 0
      end,
      run = function(items)
        require('perforated.ops').submit(ws, items[1].change)
      end,
    },
    {
      id = 'resolve',
      desc = 'Resolve',
      keys = { 'R' },
      kinds = { opened_file = true, change = true, section = true },
      multi = true,
      when = function(item, node)
        if node.kind == 'section' then
          return node.id == 'sec:attention'
        end
        if item.files then
          for _, f in ipairs(item.files) do
            if f.unresolved then
              return true
            end
          end
          return false
        end
        return item.unresolved ~= nil
      end,
      run = function(items, ctx)
        local paths
        if ctx.nodes[1].kind ~= 'section' then
          paths = paths_of(vim.tbl_filter(function(f)
            return f.unresolved ~= nil
          end, files_of(items)))
        end
        require('perforated.resolve').run(ws, paths)
        view.tree.marks = {}
      end,
    },
    {
      id = 'get_latest',
      desc = 'Get latest revision',
      keys = { 'gy' },
      kinds = { opened_file = true },
      multi = true,
      footer = 43,
      when = function(item)
        return require('perforated.status').is_stale(item)
      end,
      run = function(items)
        require('perforated.ops').sync(ws, paths_of(files_of(items)))
      end,
    },
    {
      id = 'get_revision',
      desc = 'Get revision…',
      keys = { 'g@' },
      kinds = { opened_file = true },
      when = local_with_history,
      run = function(items)
        local it = items[1]
        require('perforated.picker.sources').revision(
          ws,
          it,
          'Get revision of ' .. vim.fn.fnamemodify(it.clientFile, ':t'),
          function(r)
            require('perforated.ops').sync(ws, { p4.escape(it.clientFile) .. '#' .. r.rev })
          end
        )
      end,
    },
    {
      id = 'get_latest_change',
      desc = 'Get latest file revisions',
      keys = { 'gy' },
      kinds = { change = true },
      footer = 43,
      when = function(item)
        return vim.iter(item.files or {}):any(require('perforated.status').is_stale)
      end,
      run = function(items)
        require('perforated.ops').sync(ws, paths_of(files_of(items)))
      end,
    },
    {
      id = 'get_latest_attention',
      desc = 'Get latest revisions of these files',
      keys = { 'gy' },
      kinds = { section = true },
      footer = 43,
      when = function(_, node)
        return node.id == 'sec:attention'
      end,
      run = function(_, ctx)
        require('perforated.ops').sync(
          ws,
          paths_of(vim.tbl_map(function(c)
            return c.item
          end, ctx.node.children or {}))
        )
      end,
    },
    {
      id = 'sync',
      desc = 'Sync workspace',
      keys = { 'gY' },
      p4v = { '<C-S-g>' },
      run = function()
        require('perforated.ops').sync(ws, {}) -- asks for confirmation
      end,
    },
    {
      id = 'sync_to_change',
      desc = 'Sync workspace to this CL',
      keys = { 'g@' },
      kinds = { submitted = true, have_cl = true },
      run = function(items)
        require('perforated.ops').sync_to_change(ws, items[1].change)
      end,
    },
    {
      id = 'integrate',
      desc = 'Integrate (cherry-pick) into this workspace',
      keys = { 'I' },
      kinds = { submitted = true },
      run = function(items)
        require('perforated.integrate').run(ws, items[1].change)
      end,
    },
    {
      id = 'describe',
      desc = 'Describe changelist',
      keys = { 'gd' },
      kinds = { change = true, submitted = true, shelf = true, have_cl = true },
      nomenu = true, -- `K` (View changelist) is the menu's entry; `gd` and `?` keep this
      run = function(items)
        require('perforated.views.describe').open(ws, items[1].change)
      end,
    },
    {
      id = 'swarm_copy',
      desc = 'Copy Swarm review URL',
      keys = { 'gX' },
      kinds = { change = true, submitted = true, shelf = true, have_cl = true },
      when = function(item)
        return item and item.change ~= 'default'
      end,
      run = function(items)
        require('perforated.history').swarm(ws, items[1].change)
      end,
    },
    {
      id = 'lookup',
      desc = 'Go to changelist / path / user',
      keys = { 'g/' },
      p4v = { '<C-g>' },
      nomenu = true,
      run = function()
        require('perforated.lookup').run(ws)
      end,
    },
    {
      id = 'history',
      desc = 'File history',
      keys = { 'gL' },
      p4v = { '<C-t>' },
      kinds = { opened_file = true, shelved_file = true },
      run = function(items)
        local it = items[1]
        require('perforated.views.history').open(
          ws,
          it.depotFile or it.clientFile,
          { local_path = it.clientFile }
        )
      end,
    },
    {
      id = 'timelapse',
      desc = 'Time-lapse',
      keys = { 't' },
      p4v = { '<C-S-t>' },
      kinds = { opened_file = true, shelved_file = true },
      when = function(item)
        return item and item.action ~= 'add' and item.action ~= 'branch'
      end,
      run = function(items)
        require('perforated.views.timelapse').open(ws, items[1].depotFile or items[1].clientFile)
      end,
    },
    {
      id = 'annotate',
      desc = 'Annotate',
      keys = { 'b' },
      kinds = { opened_file = true },
      when = function(item)
        return item and item.action ~= 'add' and item.action ~= 'branch' and item.clientFile ~= nil
      end,
      run = function(items)
        vim.cmd('tabedit ' .. vim.fn.fnameescape(items[1].clientFile))
        vim.schedule(function()
          require('perforated.views.annotate').open_buf(0)
        end)
      end,
    },
    {
      id = 'diff_shelved_workspace',
      desc = 'Diff shelved vs workspace file',
      keys = { 'w' },
      kinds = { shelved_file = true, shelf = true },
      footer = 11,
      run = function(items, ctx)
        local it = items[1]
        if ctx.node.kind == 'shelf' then
          return require('perforated.diff.tab').open_shelf_vs_workspace(ws, it.change, it.shelved)
        end
        local revs = require('perforated.revs')
        revs.where(ws, { it.depotFile }, function(map)
          local path = map[it.depotFile]
          local right = (path and vim.uv.fs_stat(path)) and { path = path }
            or { empty = 'not in workspace' }
          revs.diff(ws, { spec = it.depotFile .. '@=' .. it.change }, right)
        end)
      end,
    },
    {
      id = 'view_change',
      desc = 'View changelist',
      keys = { 'K' },
      kinds = { change = true, submitted = true, shelf = true, have_cl = true },
      footer = 12,
      run = function(items)
        require('perforated.views.change_info').open(ws, items[1])
      end,
    },
    {
      id = 'diff_all',
      desc = 'Diff all files',
      keys = { 'D' },
      p4v = { '<C-d>' },
      kinds = { change = true, submitted = true, shelf = true, have_cl = true },
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
          require('perforated.ui.prompt').confirm(
            ('Revert %s? Local changes will be lost.'):format(what),
            '&Revert\n&Cancel',
            2
          ) ~= 1
        then
          return
        end
        require('perforated.checkout').revert(ws, paths_of(files), false)
        view.tree.marks = {}
      end,
    },
    {
      id = 'revert_if_unchanged',
      desc = 'Revert if unchanged',
      keys = { 'X' },
      kinds = { opened_file = true },
      multi = true,
      run = function(items)
        require('perforated.checkout').revert(ws, paths_of(files_of(items)), true)
        view.tree.marks = {}
      end,
    },
    {
      id = 'revert_unchanged',
      desc = 'Revert unchanged files',
      keys = { 'X' },
      kinds = { change = true },
      multi = true,
      run = function(items)
        require('perforated.checkout').revert(ws, paths_of(files_of(items)), true)
        view.tree.marks = {}
      end,
    },
    {
      id = 'move',
      desc = 'Move to changelist',
      keys = { 'gm' },
      kinds = FILE,
      multi = true,
      footer = 40,
      run = function(items)
        require('perforated.checkout').pick_change(ws, function(cl)
          if not cl then
            return
          end
          cls.reopen(ws, paths_of(items), cl, function(res)
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
      id = 'move_all',
      desc = 'Move all files to another changelist',
      keys = { 'gm' },
      kinds = { change = true },
      multi = true,
      footer = 41,
      when = function(item)
        return item.files ~= nil and #item.files > 0
      end,
      run = function(items)
        local files, from = {}, {}
        for _, it in ipairs(items) do
          if it.files and #it.files > 0 then
            vim.list_extend(files, it.files)
            from[it.change] = true
          end
        end
        local names = vim.tbl_map(function(c)
          return c == 'default' and 'default' or ('CL ' .. c)
        end, vim.tbl_keys(from))
        table.sort(names)
        require('perforated.checkout').pick_change(ws, function(cl)
          if not cl then
            return
          end
          cls.reopen(ws, paths_of(files), cl, function(res)
            if #res.errors > 0 then
              notify('move failed: ' .. res.errors[1], vim.log.levels.ERROR)
            else
              notify(
                ('moved %d file(s) from %s to %s'):format(
                  #res.records,
                  table.concat(names, ', '),
                  cl == 'default' and 'default' or ('CL ' .. cl)
                )
              )
            end
            view.tree.marks = {}
            require('perforated.checkout').changed(ws)
            M.refresh(view)
          end)
        end, {
          title = ('Move %d file(s) from %s to'):format(#files, table.concat(names, ', ')),
          exclude = from,
        })
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      kinds = { change = true, submitted = true, have_cl = true },
      when = function(item)
        return item.change ~= 'default'
      end,
      run = function(items)
        local text = items[1].change
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
        require('perforated.views.change_editor').new(ws)
      end,
    },
    {
      id = 'delete_change',
      desc = 'Delete changelist',
      keys = { '<Del>' },
      kinds = { change = true },
      when = function(item)
        return item.change ~= 'default'
          and #(item.files or {}) == 0
          and (item.mine ~= false or require('perforated.config').get().change.allow_force)
      end,
      run = function(items)
        require('perforated.ops').delete_change(ws, items[1].change)
      end,
    },
    {
      id = 'edit_description',
      desc = 'Edit description',
      keys = { 'C' },
      kinds = { change = true, submitted = true, have_cl = true },
      footer = 51,
      when = function(item)
        return item.change ~= 'default' and (item.mine ~= false)
      end,
      run = function(items, ctx)
        require('perforated.views.change_editor').edit(ws, items[1].change, {
          submitted = ctx.node and (ctx.node.kind == 'submitted' or ctx.node.kind == 'have_cl'),
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
        -- Each op announces PerforatedChanged, which refreshes the view (once, coalesced).
        local co = require('perforated.checkout')
        if #by.add > 0 then
          co.add(ws, by.add, ws.sticky_cl)
        end
        if #by.edit > 0 then
          co.edit(ws, by.edit, ws.sticky_cl)
        end
        if #by.delete > 0 then
          ws:run({ 'delete' }, { globals = { '-x', '-' }, stdin = by.delete }, function()
            co.changed(ws)
          end)
        end
        -- The applied files leave the section; the rest of the scan stays.
        local applied = {}
        for _, it in ipairs(items) do
          applied[it.clientFile] = true
        end
        view.reconcile.recs = vim.tbl_filter(function(r)
          return not applied[r.clientFile]
        end, view.reconcile.recs or {})
        view.tree.marks = {}
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
        -- Stops p4 itself (the scan's callback then resets the section).
        require('perforated.jobs').cancel(view.reconcile.job)
      end,
    },
    {
      id = 'reconcile_rescan',
      desc = 'Reconcile: scan again',
      keys = { 'r' },
      kinds = { section_reconcile = true, reconcile_file = true, loading = true },
      footer = 12,
      when = function(_, node)
        return (node.kind ~= 'loading' or (node.id or ''):match('^r:') ~= nil)
          and view.reconcile.state ~= 'running'
      end,
      run = function()
        view.tree.folds['sec:reconcile'] = true
        M.scan_reconcile(view)
      end,
    },
    {
      id = 'reconcile_scope',
      desc = 'Reconcile: set the paths to scan',
      keys = { 'p' },
      kinds = { section_reconcile = true, reconcile_file = true, loading = true },
      when = function(_, node)
        return node.kind ~= 'loading' or (node.id or ''):match('^r:') ~= nil
      end,
      run = function()
        local cur = table.concat(M.reconcile_scope(ws), ' ')
        require('perforated.ui.prompt').input({
          prompt = 'Reconcile paths (relative to the client root, space-separated; empty = whole client): ',
          default = cur,
          completion = 'dir',
        }, function(input)
          if input == nil then
            return
          end
          ws.reconcile_scope = vim.split(vim.trim(input), '%s+', { trimempty = true })
          view.tree.folds['sec:reconcile'] = true
          M.scan_reconcile(view)
        end)
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

--- The `.` menus of a changelist and of an opened file, in this order (`'-'` separates
--- groups). Actions not listed (send to quickfix / location list on a file) keep their keys
--- but aren't offered there; describe (`gd`) is in no menu of this view.
M.MENU_LAYOUT = {
  change = {
    { 'submit', 'Submit…' },
    '-',
    'view_change',
    'diff_all',
    'edit_description',
    'yank',
    { 'swarm_copy', 'Copy Swarm URL' },
    'to_qf',
    'get_latest_change',
    'delete_change',
    '-',
    'revert_unchanged',
    { 'revert', 'Revert files' },
    'resolve',
    'move_all',
    '-',
    { 'shelve', 'Shelve files' },
    { 'unshelve', 'Unshelve files' },
    'delete_shelved_change',
    '-',
    { 'new_change', 'Create new changelist' },
    { 'sync', 'Sync entire workspace' },
    { 'switch_client', 'Switch client' },
  },
}

M.MENU_LAYOUT.opened_file = {
  'open',
  'get_latest',
  'get_revision',
  '-',
  'revert_if_unchanged',
  'revert',
  { 'move', 'Move to another changelist' },
  'shelve',
  '-',
  'diff',
  'diff_revision',
  '-',
  'history',
  'annotate',
  { 'timelapse', 'Time-lapse view' },
  '-',
  { 'new_change', 'Create new changelist' },
  { 'sync', 'Sync entire workspace' },
  { 'switch_client', 'Switch client' },
}

--- Send nodes (files, CLs, sections) to the quickfix / location list.
function M.to_qf(view, _, ctx, loclist)
  local qf = require('perforated.ui.qf')
  local recs, shelved = {}, {}
  local function add(node)
    if node.item and (node.item.clientFile or node.item.depotFile) and not node.children then
      recs[#recs + 1] = node.item
      shelved[node.item] = node.kind == 'shelved_file' or nil
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
    -- Local path; other clients' files (`//client/path`) and shelved files open from the depot.
    if r.clientFile and r.clientFile:match('^/[^/]') then
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
    elseif not shelved[r] then
      local spec = r.haveRev and (r.depotFile .. '#' .. r.haveRev) or r.depotFile
      qitems[#qitems + 1] = qf.item(
        'perforated://' .. spec,
        ('%-10s %s'):format(r.action or '', r.change and ('CL ' .. r.change) or ''),
        { depotFile = r.depotFile, change = r.change, action = r.action, kind = 'depot' }
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

--- The window showing the view: the current one if it does, else the one it was opened in,
--- else any (in any tab).
---@return integer?
local function view_win(view)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == view.buf then
    return cur
  end
  if
    view.win
    and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_win_get_buf(view.win) == view.buf
  then
    return view.win
  end
  return vim.fn.win_findbuf(view.buf)[1]
end

function M.update_footer(view)
  if view.footer then
    -- The view's own cursor: a refresh may finish while another window is current.
    local win = view_win(view)
    local row = win and vim.api.nvim_win_get_cursor(win)[1]
    view.footer:set(keys.footer(view.actions, row and view.tree:node_at(row)))
  end
end

--- (Re)attach the key footer to the view's window.
local function attach_footer(view, win)
  if view.footer then
    if view.footer.win == win and view.footer:alive() then
      return
    end
    view.footer:detach()
  end
  view.footer = require('perforated.ui.footer').attach(win)
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
    require('perforated.views.base').code_win(vim.api.nvim_get_current_win())
  end
end

function M.close(view)
  if view.footer then
    view.footer:detach()
    view.footer = nil
  end
  local win = view_win(view)
  if view.kind == 'tab' and win and #vim.api.nvim_list_tabpages() > 1 then
    local tab = vim.api.nvim_win_get_tabpage(win)
    pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
  elseif win and require('perforated.views.base').normal_wins() > 1 then
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

--- Pick another of the user's clients and show it in this view's window. The switch is
--- checked first (`opened -m 1` with the new client fails as p4 would, e.g. for a client bound
--- to another host); on failure p4's message is shown and the view keeps its client.
---@param view table
function M.switch_client(view)
  local ws = view.ws
  cls.clients(ws, function(list, err)
    if not list then
      return notify('could not list clients: ' .. tostring(err), vim.log.levels.ERROR)
    end
    if #list == 0 then
      return notify('no clients found for ' .. tostring(ws:user()), vim.log.levels.WARN)
    end
    local current = ws:client()
    require('perforated.picker').pick({
      title = 'Switch client',
      items = list,
      format = function(c)
        return ('%s %-32s %s  %s'):format(
          c.client == current and '*' or ' ',
          c.client,
          (c.Host and c.Host ~= '') and ('@' .. c.Host) or '',
          c.Stream or c.Root or ''
        )
      end,
      preview = function(c)
        local out = {
          'Client:  ' .. c.client,
          'Root:    ' .. (c.Root or ''),
          'Host:    ' .. ((c.Host and c.Host ~= '') and c.Host or '(any)'),
        }
        if c.Stream then
          out[#out + 1] = 'Stream:  ' .. c.Stream
        end
        out[#out + 1] = ''
        vim.list_extend(out, vim.split(vim.trim(c.Description or ''), '\n', { plain = true }))
        return out
      end,
      on_choice = function(chosen)
        local c = chosen and chosen[1]
        if not c or c.client == current then
          return
        end
        local target = require('perforated.core.workspace').for_client(ws, c.client)
        target:run({ 'opened', '-m', '1' }, {}, function(res)
          if #res.errors > 0 or (not res.ok and #res.records == 0) then
            local msg = res.errors[1] or vim.trim(res.stderr or '')
            return notify(
              ('cannot switch to %s: %s'):format(c.client, msg ~= '' and msg or 'p4 failed'),
              vim.log.levels.ERROR
            )
          end
          local win = view_win(view)
          if not win then
            return
          end
          local old = view.buf
          local new = M.open(target, { kind = view.kind, win = win })
          new.origin_win = view.origin_win -- files still open where the user came from
          if vim.api.nvim_buf_is_valid(old) and old ~= (views[target.key] or {}).buf then
            pcall(vim.api.nvim_buf_delete, old, { force = true })
          end
          notify('switched to client ' .. c.client)
        end)
      end,
    })
  end)
end

--- Open (or focus) the client view of a workspace.
---@param ws perforated.Workspace
---@param opts { kind: ('tab'|'float'|'split')?, win: integer? }?  win: show it in that window
function M.open(ws, opts)
  local kind = (opts and opts.kind) or require('perforated.config').get().client_view.kind
  local origin = vim.api.nvim_get_current_win()
  local view = views[ws.key]
  if view and vim.api.nvim_buf_is_valid(view.buf) then
    local win = view_win(view)
    if opts and opts.win and win ~= opts.win then
      vim.api.nvim_win_set_buf(opts.win, view.buf)
      win = opts.win
    end
    if win then
      vim.api.nvim_set_current_win(win)
      view.win = win
    else
      view.kind = kind
      view.win = show(view.buf, kind)
    end
    attach_footer(view, view.win)
    -- `:P4` typed inside the view keeps the window files were opened from.
    if vim.api.nvim_win_get_buf(origin) ~= view.buf then
      view.origin_win = origin
    end
    M.refresh(view)
    return view
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'perforated://client/' .. (ws:client() or ws.key))
  vim.b[buf].perforated_ws = ws.key
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
  view.menu_layout = M.MENU_LAYOUT
  if opts and opts.win and vim.api.nvim_win_is_valid(opts.win) then
    vim.api.nvim_win_set_buf(opts.win, buf)
    vim.api.nvim_set_current_win(opts.win)
    view.win = opts.win
  else
    view.win = show(buf, kind)
  end
  vim.wo[view.win][0].cursorline = true
  vim.wo[view.win][0].wrap = false
  vim.wo[view.win][0].number = false
  vim.wo[view.win][0].relativenumber = false
  vim.wo[view.win][0].signcolumn = 'no'
  vim.wo[view.win][0].foldcolumn = '0'
  attach_footer(view, view.win)
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
      -- Visible in any tab (the default kind gives the view its own tab).
      if (ev.data or {}).ws ~= ws.key or #vim.fn.win_findbuf(buf) == 0 or pending_refresh then
        return
      end
      pending_refresh = true
      vim.defer_fn(function()
        pending_refresh = false
        M.refresh(view)
      end, 150)
    end,
  })
  -- Saving an opened file updates its changed/unchanged marker (one `p4 diff -sa` for it).
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      local st = require('perforated.buffer').get(ev.buf)
      if not st or st.ws ~= ws or not (st.rec and st.rec.action) then
        return
      end
      if not view.data or not view.data.modified then
        return
      end
      local modified = require('perforated.modified')
      modified.query(ws, { st.path }, function(set)
        local d = view.data
        if not set or not d or not d.modified or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        d.modified[st.key] = set[st.key]
        d.overlay = modified.overlay(ws)
        view.tree:set(build(view, d))
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      views[ws.key] = nil
      if view.footer then
        view.footer:detach()
      end
      if view.reconcile.state == 'running' then
        require('perforated.jobs').cancel(view.reconcile.job)
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- The footer belongs to the view, not the window: drop it when another buffer takes the
  -- window, restore it when the view comes back.
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = buf,
    callback = function()
      if view.footer then
        view.footer:detach()
        view.footer = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      view.win = vim.api.nvim_get_current_win()
      attach_footer(view, view.win)
      M.update_footer(view)
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

M._actions = actions -- for the generated help (scripts/gen_doc.lua)

return M
