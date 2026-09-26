--- `:P4 describe N`: a Magit-style changelist buffer — header, description, files and shelved
--- files. `<Tab>` expands a file's unified diff inline (computed in-process from two prints,
--- only when expanded); `d` opens the side-by-side diff, `D` the diff tab of every file.
---
--- Pending changelists of this client diff the workspace file against its base; shelved files
--- default to the shelf against its base revision (the menu adds vs workspace and vs head).

local base = require('perforated.views.base')
local cls = require('perforated.changelists')
local revs = require('perforated.revs')

local M = {}

local MAX_INLINE = 20000 -- lines per side; above this, `d` only

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- The two sides of a file entry.
---@param f table  file item
---@return perforated.RevSide left, perforated.RevSide right
local function sides(f)
  local add = f.action == 'add'
    or f.action == 'branch'
    or f.action == 'move/add'
    or f.action == 'import'
  local del = f.action == 'delete' or f.action == 'move/delete' or f.action == 'purge'
  if f.shelved then
    local r = tonumber(f.rev)
    local left = (add or not r or r < 1) and { empty = 'added' }
      or { spec = f.depotFile .. '#' .. f.rev }
    return left, del and { empty = 'deleted' } or { spec = f.depotFile .. '@=' .. f.change }
  end
  if f.status == 'submitted' then
    local r = tonumber(f.rev) or 1
    local left = (add or r <= 1) and { empty = 'added' } or { spec = f.depotFile .. '#' .. (r - 1) }
    return left, del and { empty = 'deleted' } or { spec = f.depotFile .. '#' .. r }
  end
  -- Pending: the workspace file against its base (only for files opened in this client).
  local left
  if f.base_spec then
    left = { spec = f.base_spec }
  elseif add then
    left = { empty = 'added' }
  else
    left = { spec = f.depotFile .. '#' .. (f.rev or 'have') }
  end
  local right = del and { empty = 'deleted' } or (f.clientFile and { path = f.clientFile }) or nil
  return left, right
end
M._sides = sides

local DIFF_HL =
  { ['+'] = 'PerforatedDiffAdded', ['-'] = 'PerforatedDiffRemoved', ['@'] = 'PerforatedDiffHunk' }

--- Lazily fill a file node with its inline diff.
local function load_diff(view, node)
  local f = node.item
  local left, right = sides(f)
  if not right then
    node.children = {
      {
        id = node.id .. ':na',
        kind = 'note',
        text = { { 'opened in another workspace: content not available', 'PerforatedDim' } },
      },
    }
    return
  end
  node.children = {
    { id = node.id .. ':loading', kind = 'note', text = { { 'loading…', 'PerforatedLoading' } } },
  }
  local got, a, b, err = 0, nil, nil, nil
  local function done()
    got = got + 1
    if got < 2 then
      return
    end
    local children = {}
    if not a or not b then
      children[1] = {
        id = node.id .. ':err',
        kind = 'note',
        text = { { 'could not load: ' .. tostring(err), 'ErrorMsg' } },
      }
    elseif #a > MAX_INLINE or #b > MAX_INLINE then
      children[1] = {
        id = node.id .. ':big',
        kind = 'note',
        text = { { 'too large to show inline — d for a side-by-side diff', 'PerforatedDim' } },
      }
    else
      local new_l = 0
      for i, l in ipairs(revs.unified(a, b)) do
        local c = l:sub(1, 1)
        if c == '@' then
          new_l = tonumber(l:match('%+(%d+)')) or 1
        end
        children[#children + 1] = {
          id = node.id .. ':' .. i,
          kind = 'diff_line',
          item = { file = f, lnum = math.max(new_l, 1), old = c == '-' },
          text = { { l, DIFF_HL[c] } },
        }
        if c == ' ' or c == '+' then
          new_l = new_l + 1
        end
      end
      if #children == 0 then
        children[1] = {
          id = node.id .. ':same',
          kind = 'note',
          text = { { 'no content changes', 'PerforatedDim' } },
        }
      end
    end
    node.children = children
    if vim.api.nvim_buf_is_valid(view.buf) then
      view.tree:render()
    end
  end
  revs.lines(view.ws, left, function(l, e)
    a, err = l, err or e
    done()
  end)
  revs.lines(view.ws, right, function(l, e)
    b, err = l, err or e
    done()
  end)
end

local function file_node(view, f, id_prefix)
  local rev = f.rev and ('#' .. f.rev) or ''
  -- ● changed / dimmed unchanged, for this client's opened files
  local changed
  if not f.shelved and view.data and view.data.modified ~= nil then
    local modified = require('perforated.modified')
    view.data.overlay = view.data.overlay or modified.overlay(view.ws)
    changed = modified.is_changed(view.ws, f, view.data.modified, view.data.overlay)
  end
  local marker, row_hl = require('perforated.modified').marker(changed)
  local node = {
    id = id_prefix .. f.depotFile,
    kind = f.shelved and 'describe_shelved' or 'describe_file',
    item = f,
    open = false,
    children = {},
    on_open = function(n)
      load_diff(view, n)
    end,
    text = {
      marker or { '' },
      {
        ('%-10s'):format(f.action or ''),
        f.shelved and 'PerforatedShelvedFile'
          or (row_hl == 'PerforatedUnchanged' and row_hl or 'PerforatedAction'),
      },
      { f.depotFile, f.shelved and 'PerforatedShelvedFile' or row_hl or 'PerforatedPath' },
      { rev, 'PerforatedRev' },
    },
  }
  if view.tree.folds[node.id] then -- expanded before a refresh: reload its diff
    node.loaded = true
    load_diff(view, node)
  end
  return node
end

local function render(view)
  local d = view.data
  local rec = d.rec
  local roots = {}
  local title = rec.change == 'default' and 'default changelist' or ('CL ' .. rec.change)
  roots[#roots + 1] = {
    id = 'hdr',
    kind = 'header',
    item = view.item,
    text = {
      { title, 'PerforatedTitle' },
      {
        '  ' .. (rec.status or ''),
        rec.status == 'submitted' and 'PerforatedDim' or 'PerforatedChangelist',
      },
      { ('  %s@%s'):format(rec.user or '?', rec.client or '?'), 'PerforatedHeader' },
      {
        '  ' .. (rec.time and os.date('%Y-%m-%d %H:%M', tonumber(rec.time)) or ''),
        'PerforatedDim',
      },
    },
  }
  if rec.desc and vim.trim(rec.desc) ~= '' then
    for i, l in ipairs(vim.split(vim.trim(rec.desc), '\n', { plain = true })) do
      roots[#roots + 1] =
        { id = 'desc:' .. i, kind = 'header', item = view.item, text = { { l, 'Normal' } } }
    end
  end
  local files = {}
  for _, f in ipairs(d.files) do
    files[#files + 1] = file_node(view, f, 'f:')
  end
  roots[#roots + 1] = {
    id = 'sec:files',
    kind = 'section',
    item = view.item,
    text = { { ('Files (%d)'):format(#d.files), 'PerforatedSection' } },
    children = files,
  }
  if #d.shelved > 0 then
    local sh = {}
    for _, f in ipairs(d.shelved) do
      sh[#sh + 1] = file_node(view, f, 's:')
    end
    roots[#roots + 1] = {
      id = 'sec:shelved',
      kind = 'section',
      item = view.item,
      text = { { ('Shelved (%d)'):format(#d.shelved), 'PerforatedShelved' } },
      children = sh,
    }
  end
  view.tree:set(roots)
end

--- Fetch everything the buffer shows: describe (+ shelved files and, for this client's pending
--- changelists, the opened files' fstat records for workspace paths and bases).
local function load(view, cb)
  local ws, change = view.ws, view.change
  local function finish(rec, files, shelved, modified)
    for _, f in ipairs(files) do
      f.change, f.status = rec.change, rec.status
    end
    for _, f in ipairs(shelved) do
      f.change, f.status, f.shelved = rec.change, rec.status, true
    end
    view.data = { rec = rec, files = files, shelved = shelved, modified = modified }
    view.item = {
      change = rec.change,
      status = rec.status,
      user = rec.user,
      client = rec.client,
      desc = rec.desc,
    }
    cb()
  end
  local function opened(rec, fallback, shelved)
    if ws.mode == 'connection' or rec.client ~= ws:client() then
      return finish(rec, fallback, shelved)
    end
    local p4 = require('perforated.p4')
    p4.fstat_opened(ws, {}, function(recs)
      local files = {}
      for _, r in ipairs(recs or {}) do
        if (r.change or 'default') == rec.change then
          files[#files + 1] = {
            depotFile = r.depotFile,
            clientFile = r.clientFile,
            action = r.action,
            rev = r.haveRev,
            base_spec = p4.base_spec(r),
          }
        end
      end
      if #files == 0 then
        return finish(rec, fallback, shelved)
      end
      local paths = vim.tbl_map(function(f)
        return f.clientFile
      end, files)
      require('perforated.modified').query(ws, paths, function(set)
        finish(rec, files, shelved, set or false)
      end)
    end)
  end
  if change == 'default' then
    return opened(
      { change = 'default', status = 'pending', user = ws:user(), client = ws:client() },
      {},
      {}
    )
  end
  cls.describe(ws, { change }, {}, function(by)
    local d = by[change]
    if not d then
      view.error = 'no such changelist: ' .. change
      return cb()
    end
    if d.rec.status ~= 'pending' then
      return finish(d.rec, d.files, {})
    end
    cls.shelved_files(ws, { change }, function(sh)
      opened(d.rec, d.files, sh[change] or {})
    end)
  end)
end

---@param view table
---@param f table
---@return perforated.RevSide?
local function workspace_side(view, f, cb)
  revs.where(view.ws, { f.depotFile }, function(map)
    cb(map[f.depotFile] and { path = map[f.depotFile] } or nil)
  end)
end

local function actions(view)
  local ws = view.ws
  local FILE = { describe_file = true, describe_shelved = true, diff_line = true }
  local function file_of(item)
    return item.file or item
  end
  local list = base.nav(view, 'Describe')
  vim.list_extend(list, {
    {
      id = 'open_line',
      desc = 'Open file at this line',
      keys = { '<CR>' },
      kinds = { diff_line = true },
      nomenu = true,
      run = function(items)
        local it = items[1]
        local left, right = sides(it.file)
        revs.open(ws, it.old and left or right or left, it.lnum)
      end,
    },
    {
      id = 'toggle',
      desc = 'Expand / collapse',
      keys = { '<CR>' },
      nomenu = true,
      when = function(_, node)
        return node and node.children ~= nil
      end,
      run = function(_, ctx)
        view.tree:toggle(ctx.node)
      end,
    },
    {
      id = 'diff',
      desc = 'Diff',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = { describe_file = true, diff_line = true },
      footer = 10,
      run = function(items)
        local left, right = sides(file_of(items[1]))
        if not right then
          return notify('opened in another workspace: content not available', vim.log.levels.WARN)
        end
        revs.diff(ws, left, right)
      end,
    },
    {
      id = 'diff_shelved',
      desc = 'Diff shelved vs base revision',
      keys = { 'd' },
      p4v = { '<C-d>' },
      kinds = { describe_shelved = true },
      footer = 10,
      run = function(items)
        revs.diff(ws, sides(items[1]))
      end,
    },
    {
      id = 'diff_shelved_workspace',
      desc = 'Diff shelved vs workspace file',
      keys = { 'w', 'gw' },
      kinds = { describe_shelved = true },
      run = function(items)
        local f = items[1]
        workspace_side(view, f, function(side)
          if not side then
            return notify(f.depotFile .. ' is not in this workspace', vim.log.levels.WARN)
          end
          revs.diff(ws, side, { spec = f.depotFile .. '@=' .. f.change })
        end)
      end,
    },
    {
      id = 'diff_shelf_workspace',
      desc = 'Diff every shelved file vs workspace',
      keys = { 'w', 'gw' },
      kinds = { section = true },
      when = function(_, node)
        return node.id == 'sec:shelved'
      end,
      run = function()
        require('perforated.diff.tab').open_shelf_vs_workspace(
          ws,
          view.item.change,
          view.data.shelved
        )
      end,
    },
    {
      id = 'diff_shelved_head',
      desc = 'Diff shelved vs head revision',
      keys = { 'gh' },
      kinds = { describe_shelved = true },
      run = function(items)
        local f = items[1]
        revs.diff(ws, { spec = f.depotFile .. '#head' }, { spec = f.depotFile .. '@=' .. f.change })
      end,
    },
    {
      id = 'diff_all',
      desc = 'Diff all files',
      keys = { 'D' },
      footer = 11,
      run = function()
        local it = vim.tbl_extend('force', {}, view.item)
        if it.status == 'pending' then
          it.files = vim.tbl_map(
            function(f)
              return {
                depotFile = f.depotFile,
                clientFile = f.clientFile,
                action = f.action,
                haveRev = f.rev,
                change = f.change,
              }
            end,
            vim.tbl_filter(function(f)
              return f.clientFile ~= nil
            end, view.data.files)
          )
          if #it.files == 0 then
            it.files = nil
            it.shelved = view.data.shelved
          end
        end
        require('perforated.diff.tab').open_change(ws, it)
      end,
    },
    {
      id = 'open',
      desc = 'Open file',
      keys = { 'o' },
      kinds = FILE,
      footer = 12,
      run = function(items)
        local left, right = sides(file_of(items[1]))
        revs.open(ws, right or left)
      end,
    },
    {
      id = 'history',
      desc = 'File history',
      keys = { 'L' },
      p4v = { '<C-t>' },
      kinds = FILE,
      footer = 13,
      run = function(items)
        require('perforated.views.history').open(ws, file_of(items[1]).depotFile)
      end,
    },
    {
      id = 'annotate',
      desc = 'Annotate',
      keys = { 'b' },
      kinds = { describe_file = true, diff_line = true },
      run = function(items)
        local f = file_of(items[1])
        local _, right = sides(f)
        if right and right.spec then
          require('perforated.views.annotate').open_spec(ws, right.spec)
        elseif right and right.path then
          vim.cmd('tabedit ' .. vim.fn.fnameescape(right.path))
          require('perforated.views.annotate').open_buf(0)
        end
      end,
    },
    {
      id = 'edit_description',
      desc = 'Edit description',
      keys = { 'C' },
      footer = 20,
      when = function()
        local it = view.item
        return it.change ~= 'default'
          and (it.user == ws:user() or require('perforated.config').get().change.allow_force)
      end,
      run = function()
        require('perforated.views.change_editor').edit(ws, view.item.change, {
          submitted = view.item.status == 'submitted',
          on_done = view.refresh,
        })
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      when = function()
        return view.item.change ~= 'default'
      end,
      run = function()
        vim.fn.setreg('"', view.item.change)
        pcall(vim.fn.setreg, '+', view.item.change)
        notify('copied ' .. view.item.change)
      end,
    },
    {
      id = 'submit',
      desc = 'Submit',
      keys = { 'P' },
      p4v = { '<C-s>' },
      when = function()
        return view.item.status == 'pending'
          and view.item.client == ws:client()
          and #view.data.files > 0
      end,
      run = function()
        require('perforated.ops').submit(ws, view.item.change, function()
          view.refresh()
        end)
      end,
    },
    {
      id = 'delete_change',
      desc = 'Delete changelist',
      keys = { '<Del>' },
      when = function()
        local it = view.item
        return it.status == 'pending'
          and it.change ~= 'default'
          and (it.client == ws:client() or require('perforated.config').get().change.allow_force)
      end,
      run = function()
        require('perforated.ops').delete_change(ws, view.item.change, function(ok)
          if ok then
            base.close(view)
          end
        end)
      end,
    },
    {
      id = 'sync_to_change',
      desc = 'Sync workspace to this CL',
      keys = { 'g@' },
      when = function()
        return view.item.status == 'submitted' and ws.mode ~= 'connection'
      end,
      run = function()
        require('perforated.ops').sync_to_change(ws, view.item.change)
      end,
    },
    {
      id = 'integrate',
      desc = 'Integrate (cherry-pick) into this workspace',
      keys = { 'I' },
      when = function()
        return view.item.status == 'submitted' and ws.mode ~= 'connection'
      end,
      run = function()
        require('perforated.integrate').run(ws, view.item.change)
      end,
    },
    {
      id = 'to_qf',
      desc = 'Files to quickfix',
      keys = { 'Q' },
      run = function()
        M.to_qf(view)
      end,
    },
    {
      id = 'swarm',
      desc = 'Open review in Swarm',
      keys = { 'gx' },
      when = function()
        return view.item.change ~= 'default'
      end,
      run = function()
        require('perforated.history').swarm(ws, view.item.change)
      end,
    },
    {
      id = 'swarm_copy',
      desc = 'Copy Swarm review URL',
      keys = { 'gX' },
      when = function()
        return view.item.change ~= 'default'
      end,
      run = function()
        require('perforated.history').swarm(ws, view.item.change, true)
      end,
    },
  })
  return list
end

--- `Q`: the changelist's files in the quickfix list — workspace paths when mapped, else
--- `perforated://` revisions (`@=CL` for shelved files).
function M.to_qf(view)
  local d = view.data
  local all = vim.list_extend(vim.list_extend({}, d.files), d.shelved)
  local depot = vim.tbl_map(function(f)
    return f.depotFile
  end, all)
  local qf = require('perforated.ui.qf')
  local title = view.item.change == 'default' and 'default' or ('CL ' .. view.item.change)
  revs.where(view.ws, depot, function(map)
    local items = {}
    for _, f in ipairs(all) do
      local path = f.clientFile or map[f.depotFile]
      local deleted = f.action == 'delete' or f.action == 'move/delete'
      if f.shelved then
        path = require('perforated.uri').name(f.depotFile .. '@=' .. f.change)
      elseif not path or (deleted and f.status == 'submitted') then
        local r = tonumber(f.rev)
        local spec = f.depotFile
          .. (f.status == 'submitted' and ('@' .. f.change) or ('#' .. (f.rev or 'head')))
        if deleted and r then
          spec = f.depotFile .. '#' .. (r - 1)
        end
        path = require('perforated.uri').name(spec)
      end
      items[#items + 1] = qf.item(
        path,
        ('%s%s %s'):format(f.shelved and 'shelved ' or '', f.action or '', f.depotFile),
        {
          depotFile = f.depotFile,
          rev = f.rev,
          change = f.change,
          action = f.action,
          kind = f.shelved and 'shelved_file' or 'describe_file',
        }
      )
    end
    qf.set({ title = 'P4 describe ' .. title, kind = 'describe', items = items })
  end)
end

--- Open the describe buffer for a changelist.
---@param ws perforated.Workspace
---@param change string|integer
---@return table view
function M.open(ws, change)
  change = tostring(change)
  require('perforated.hl').setup()
  local buf, win = base.tab('perforated://describe/' .. change)
  local view = { ws = ws, buf = buf, win = win, change = change, item = { change = change } }
  view.tree = require('perforated.ui.tree').new(buf)
  view.tree:set({
    {
      id = 'loading',
      kind = 'note',
      text = { { 'CL ' .. change .. ' — loading…', 'PerforatedLoading' } },
    },
  })
  function view.refresh()
    load(view, function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if view.error then
        return view.tree:set({
          { id = 'err', kind = 'note', text = { { view.error, 'ErrorMsg' } } },
        })
      end
      render(view)
      if view.update_footer then
        view.update_footer()
      end
    end)
  end
  view.actions = actions(view)
  base.finish(view)
  M._last = view
  view.refresh()
  return view
end

return M
