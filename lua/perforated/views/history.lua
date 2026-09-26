--- File history (`:P4 filelog`, `L`, `<C-t>`): one `filelog -l -i -m N` call per page.
---
--- Presenters (`history.presenter`): 'float' (default), 'picker' or 'quickfix' (location list of
--- `perforated://file#rev` entries). `<CR>` on a revision opens its action menu: diff vs the
--- previous revision, diff vs the workspace file, describe the changelist, open the revision
--- read-only, annotate it. A directory's history is its submitted changelists (`changes dir/...`).

local base = require('perforated.views.base')
local history = require('perforated.history')
local revs = require('perforated.revs')

local M = {}

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- The revision before `r` (following a branch/copy back to its source at rev 1).
---@param r perforated.Rev
---@return perforated.RevSide
local function previous(r)
  local n = tonumber(r.rev) or 1
  if
    n > 1
    and r.action ~= 'add'
    and r.action ~= 'branch'
    and r.action ~= 'move/add'
    and r.action ~= 'import'
  then
    return { spec = r.depotFile .. '#' .. (n - 1) }
  end
  if r.from and r.from.file and (r.from.how or ''):match('from$') then
    return { spec = r.from.file .. (r.from.erev or '#head') }
  end
  return { empty = 'added' }
end

local function is_deleted(r)
  return r.action == 'delete' or r.action == 'move/delete' or r.action == 'purge'
end

local function this_side(r)
  if is_deleted(r) then
    return { empty = 'deleted' }
  end
  return { spec = r.depotFile .. '#' .. r.rev }
end

---@param r perforated.Rev
---@return string
local function rev_text(r)
  return ('#%-4s CL %-8s %s  %-12s %-10s %s'):format(
    r.rev,
    r.change,
    base.date(r.time),
    r.user or '',
    r.action or '',
    base.first_line(r.desc)
  )
end

--- Actions on a revision item (`{ rev = perforated.Rev, ws, path, local_path }`), shared by the
--- float, the picker's follow-up menu and the location list.
---@param ctx { ws: perforated.Workspace, local_path: string? }
---@return perforated.Action[]
function M.rev_actions(ctx)
  local ws = ctx.ws
  local K = { rev = true }
  return {
    {
      id = 'diff_prev',
      desc = 'Diff against previous revision',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = K,
      footer = 10,
      run = function(items)
        local r = items[1]
        revs.diff(ws, previous(r), this_side(r))
      end,
    },
    {
      id = 'diff_workspace',
      desc = 'Diff against workspace file',
      keys = { 'w' },
      kinds = K,
      footer = 11,
      when = function()
        return ws.mode ~= 'connection'
      end,
      run = function(items)
        local r = items[1]
        local function go(path)
          if not path then
            return notify(r.depotFile .. ' is not in this workspace', vim.log.levels.WARN)
          end
          revs.diff(ws, this_side(r), { path = path })
        end
        if ctx.local_path and r.depotFile == ctx.depot then
          return go(ctx.local_path)
        end
        revs.where(ws, { r.depotFile }, function(map)
          go(map[r.depotFile])
        end)
      end,
    },
    {
      id = 'describe',
      desc = 'Describe changelist',
      keys = { 'gd' },
      kinds = K,
      footer = 12,
      run = function(items)
        require('perforated.views.describe').open(ws, items[1].change)
      end,
    },
    {
      id = 'view_change',
      desc = 'View changelist',
      keys = { 'K' },
      kinds = K,
      run = function(items)
        require('perforated.views.change_info').open(ws, { change = items[1].change })
      end,
    },
    {
      id = 'open_rev',
      desc = 'Open revision (read-only)',
      keys = { 'o' },
      kinds = K,
      footer = 13,
      run = function(items)
        revs.open(ws, this_side(items[1]))
      end,
    },
    {
      id = 'timelapse',
      desc = 'Time-lapse',
      keys = { 't' },
      p4v = { '<C-S-t>' },
      kinds = K,
      run = function(items)
        require('perforated.views.timelapse').open(
          ws,
          items[1].depotFile,
          { rev = tonumber(items[1].rev) }
        )
      end,
    },
    {
      id = 'annotate',
      desc = 'Annotate this revision',
      keys = { 'b' },
      kinds = K,
      when = function(item)
        return item and not is_deleted(item)
      end,
      run = function(items)
        require('perforated.views.annotate').open_spec(
          ws,
          items[1].depotFile .. '#' .. items[1].rev
        )
      end,
    },
    {
      id = 'sync_to_change',
      desc = 'Sync workspace to this CL',
      keys = { 'g@' },
      kinds = K,
      when = function()
        return ws.mode ~= 'connection'
      end,
      run = function(items)
        require('perforated.ops').sync_to_change(ws, items[1].change)
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      kinds = K,
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
      kinds = K,
      run = function(items)
        history.swarm(ws, items[1].change)
      end,
    },
  }
end

--- A one-item "view" so the action registry works outside a tree (picker, quickfix).
---@param item any
local function single(item, kind)
  local node = { id = 'x', kind = kind, item = item }
  return {
    tree = {
      node_at = function()
        return node
      end,
      marked = function()
        return {}
      end,
    },
  }
end
M._single = single

--- Show the action menu for one revision (picker / quickfix presenters).
---@param ctx table
---@param r perforated.Rev
function M.rev_menu(ctx, r)
  require('perforated.ui.keys').menu(M.rev_actions(ctx), single(r, 'rev'))
end

local function loclist(ctx, list, win)
  local qf = require('perforated.ui.qf')
  local uri = require('perforated.uri')
  local items = {}
  for _, r in ipairs(list) do
    if not is_deleted(r) then
      items[#items + 1] = qf.item(uri.name(r.depotFile .. '#' .. r.rev), rev_text(r), {
        depotFile = r.depotFile,
        rev = r.rev,
        change = r.change,
        action = r.action,
        kind = 'rev',
      })
    end
  end
  qf.set({
    title = 'P4 filelog ' .. ctx.depot,
    kind = 'history',
    items = items,
    loclist = true,
    win = win,
  })
end

local function render(view)
  local roots, groups, order = {}, {}, {}
  for _, r in ipairs(view.revs) do
    if not groups[r.depotFile] then
      groups[r.depotFile] = {}
      order[#order + 1] = r.depotFile
    end
    table.insert(groups[r.depotFile], r)
  end
  for gi, file in ipairs(order) do
    local rows = {}
    for _, r in ipairs(groups[file]) do
      rows[#rows + 1] = {
        id = file .. '#' .. r.rev,
        kind = 'rev',
        item = r,
        text = {
          { ('#%-4s'):format(r.rev), 'PerforatedRev' },
          { (' CL %-8s'):format(r.change), 'PerforatedChangelist' },
          { ' ' .. base.date(r.time), 'PerforatedDim' },
          { ('  %-12s'):format(r.user or ''), 'PerforatedHeader' },
          { ('%-10s'):format(r.action or ''), 'PerforatedAction' },
          { base.first_line(r.desc), 'PerforatedPath' },
        },
      }
    end
    if gi == 1 then
      vim.list_extend(roots, rows)
    else
      roots[#roots + 1] = {
        id = 'from:' .. file,
        kind = 'section',
        text = { { 'branched from ' .. file, 'PerforatedSection' } },
        children = rows,
      }
    end
  end
  if view.more and #roots > 0 then
    roots[#roots + 1] = {
      id = 'more',
      kind = 'more',
      text = { { view.loading and 'loading…' or '… more (gn)', 'PerforatedDim' } },
    }
  end
  if #roots == 0 then
    roots[1] = {
      id = 'none',
      kind = 'note',
      text = { { view.more and 'loading…' or 'no history', 'PerforatedDim' } },
    }
  end
  view.tree:set(roots)
end

--- Load the next page (all of it for the first call).
local function load_page(view, cb)
  if view.loading or not view.more then
    return
  end
  view.loading = true
  local limit = require('perforated.config').get().history.limit
  local oldest
  for i = #view.revs, 1, -1 do
    if view.revs[i].depotFile == view.depot then
      oldest = tonumber(view.revs[i].rev)
      break
    end
  end
  if oldest and oldest <= 1 then
    view.loading, view.more = false, false
    return cb and cb()
  end
  history.filelog(
    view.ws,
    view.depot,
    { max = limit, before = oldest and oldest - 1 },
    function(list, err)
      view.loading = false
      if not list then
        view.more = false
        notify(tostring(err), vim.log.levels.ERROR)
        return cb and cb()
      end
      local seen, own = view.seen, 0
      for _, r in ipairs(list) do
        local k = r.depotFile .. '#' .. r.rev
        if not seen[k] then
          seen[k] = true
          view.revs[#view.revs + 1] = r
        end
        if r.depotFile == view.depot or (not view.depot_known and own == 0) then
          own = own + 1
        end
      end
      if not view.depot_known and list[1] then
        view.depot, view.depot_known = list[1].depotFile, true
        view.ctx.depot = view.depot
      end
      view.more = own >= limit
      if cb then
        cb()
      end
    end
  )
end

--- Open the history of a file (depot path or local path).
---@param ws perforated.Workspace
---@param path string
---@param opts { presenter: string?, local_path: string? }?
function M.open(ws, path, opts)
  opts = opts or {}
  path = path:gsub('[#@].*$', '')
  local is_dir = path:match('/%.%.%.$') or path:match('/$') or vim.fn.isdirectory(path) == 1
  if is_dir then
    local dir = path:gsub('/%.%.%.$', ''):gsub('/$', '')
    return require('perforated.views.changes').open(ws, { path = dir .. '/...' })
  end
  local local_path = opts.local_path or (not path:match('^//') and path or nil)
  local presenter = opts.presenter or require('perforated.config').get().history.presenter
  local ctx = { ws = ws, local_path = local_path, depot = path }
  local view = {
    ws = ws,
    depot = path,
    depot_known = path:match('^//') ~= nil,
    revs = {},
    seen = {},
    more = true,
    ctx = ctx,
  }

  if presenter == 'picker' or presenter == 'quickfix' then
    local win = vim.api.nvim_get_current_win()
    return load_page(view, function()
      if presenter == 'quickfix' then
        return loclist(ctx, view.revs, win)
      end
      require('perforated.picker').pick({
        title = 'History · ' .. view.depot,
        items = view.revs,
        format = rev_text,
        preview = function(r)
          local out =
            { ('CL %s · %s · %s'):format(r.change, r.user or '?', base.date(r.time)), '' }
          return vim.list_extend(out, vim.split(r.desc or '', '\n', { plain = true }))
        end,
        on_choice = function(chosen)
          if chosen then
            M.rev_menu(ctx, chosen[1])
          end
        end,
      })
    end)
  end

  require('perforated.hl').setup()
  local buf, win = base.float('perforated://history/' .. path, 'History · ' .. path)
  view.buf, view.win = buf, win
  view.tree = require('perforated.ui.tree').new(buf)
  local function paint()
    if vim.api.nvim_buf_is_valid(buf) then
      render(view)
      if view.update_footer then
        view.update_footer()
      end
    end
  end
  function view.refresh()
    view.revs, view.seen, view.more = {}, {}, true
    load_page(view, paint)
  end
  view.actions = base.nav(view, 'History', { expand_menu = true })
  vim.list_extend(view.actions, M.rev_actions(ctx))
  vim.list_extend(view.actions, {
    {
      id = 'more',
      desc = 'Load more',
      keys = { 'gn' },
      nomenu = true,
      run = function()
        load_page(view, paint)
        paint()
      end,
    },
    {
      id = 'to_loclist',
      desc = 'History to location list',
      keys = { 'Q' },
      nomenu = true,
      run = function()
        local list = view.revs
        base.close(view)
        loclist(ctx, list, vim.api.nvim_get_current_win())
      end,
    },
  })
  base.finish(view)
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      local node = view.tree:node_at()
      if node and node.kind == 'more' and not view.loading then
        load_page(view, paint)
      end
    end,
  })
  M._last = view
  paint()
  load_page(view, paint)
  return view
end

--- History of the current buffer's file (its depot path when known).
---@param buf integer?
function M.open_buf(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf or vim.api.nvim_get_current_buf()
  local spec = vim.b[buf].perforated_spec
  local ws
  if spec then
    ws = require('perforated.core.workspace').get(vim.b[buf].perforated_ws)
      or require('perforated.core.workspace').connection()
    return M.open(ws, spec)
  end
  local st = require('perforated.buffer').get(buf)
  if not st then
    return notify('not a Perforce file', vim.log.levels.WARN)
  end
  local depot = st.rec and st.rec.depotFile
  if st.rec and st.rec.action == 'add' then
    return notify('opened for add: no history yet', vim.log.levels.INFO)
  end
  M.open(st.ws, depot or st.path, { local_path = st.path })
end

return M
