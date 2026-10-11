--- `:P4 changes [-u user] [-m N] [path]`: submitted changelists, newest first, paginated.
---
--- Scoped to the client view by default (`path` overrides). `gn` / reaching the end loads the
--- next page (`path@<oldest-1>`), so no query is unbounded. Actions: D diff all files, C edit
--- description (own CLs; `i`), K view changelist, y copy CL number, Q quickfix of the CL's files is left to the diff tab.
--- `l` expands a changelist into its files (one `describe -s`, on first expand); `d` diffs a
--- file's revision against the previous one.

local base = require('perforated.views.base')
local cls = require('perforated.changelists')
local keys = require('perforated.ui.keys')

local M = {}

local first_line = base.first_line

--- A file of a submitted changelist: `#rev` against `#rev-1`.
local function file_node(change, f)
  f.status, f.change = 'submitted', change
  return {
    id = ('subf:%s:%s'):format(change, f.depotFile),
    kind = 'submitted_file',
    item = f,
    text = {
      { ('%-10s'):format(f.action or ''), 'PerforatedAction' },
      { f.depotFile, 'PerforatedPath' },
      { '#' .. (f.rev or '?'), 'PerforatedRev' },
    },
  }
end

--- Fill a changelist node with its files (first expand, and again after a reload).
local function load_files(view, node)
  local change = node.item.change
  node.children =
    { { id = node.id .. ':loading', kind = 'note', text = { { 'loading…', 'PerforatedDim' } } } }
  cls.describe(view.ws, { change }, {}, function(by)
    local d = by[change]
    local files = {}
    for _, f in ipairs(d and d.files or {}) do
      files[#files + 1] = file_node(change, f)
    end
    if #files == 0 then
      files[1] = {
        id = node.id .. ':none',
        kind = 'note',
        text = { { d and 'no files' or 'could not describe CL ' .. change, 'PerforatedDim' } },
      }
    end
    node.children = files
    if vim.api.nvim_buf_is_valid(view.buf) then
      view.tree:render()
    end
  end)
end

--- Make a submitted-changelist node expand into its files (here and in the client view's
--- "Recent submitted"). `view` needs `ws`, `buf` and `tree`.
---@param view table
---@param node perforated.TreeNode
---@return perforated.TreeNode node
function M.expandable(view, node)
  node.open = false
  node.children = {}
  node.on_open = function(n)
    load_files(view, n)
  end
  if view.tree.folds[node.id] then -- expanded before a refresh: fetch its files again
    node.loaded = true
    load_files(view, node)
  end
  return node
end

--- Diff a submitted file's revision against the previous one.
---@param ws perforated.Workspace
---@param f table  a `submitted_file` item
function M.diff_file(ws, f)
  local left, right = require('perforated.views.describe')._sides(f)
  require('perforated.revs').diff(ws, left, right)
end

--- The `.` menu on a submitted changelist and on one of its files (here and in the client
--- view's "Recent submitted"). Actions not listed keep their keys (`gd` describe).
M.MENU_LAYOUT = {
  submitted = {
    'view_change',
    'yank',
    '-',
    'diff_all',
    'integrate',
    'edit_description', -- your own changelists
    'sync_to_change',
    'swarm_copy',
    '-', -- the client view's "Recent submitted" only:
    'all_submitted',
    { 'sync', 'Sync entire workspace' },
    { 'switch_client', 'Switch client' },
  },
  submitted_file = {
    'open_revision',
    '-',
    'history',
    { 'timelapse', 'Time-lapse view' },
    'diff_file',
    'diff_file_revision',
    '-',
    'view_change',
  },
}

--- Actions on a file of a submitted changelist, shared with the client view: open that
--- revision, diff it against the previous one or against another revision.
---@param ws perforated.Workspace
---@return perforated.Action[]
function M.file_actions(ws)
  local deleted = require('perforated.history').deleted
  return {
    {
      id = 'open_revision',
      desc = 'Open',
      keys = { 'o' },
      kinds = { submitted_file = true },
      when = function(item)
        return not deleted(item.action)
      end,
      run = function(items)
        local f = items[1]
        require('perforated.revs').open(ws, { spec = f.depotFile .. '#' .. f.rev })
      end,
    },
    {
      id = 'diff_file',
      desc = 'Diff against previous revision',
      keys = { 'd', '<CR>' },
      p4v = { '<C-d>' },
      kinds = { submitted_file = true },
      footer = 10,
      run = function(items)
        M.diff_file(ws, items[1])
      end,
    },
    {
      id = 'diff_file_revision',
      desc = 'Diff against revision…',
      keys = { 'gD' },
      kinds = { submitted_file = true },
      when = function(item)
        return not deleted(item.action)
      end,
      run = function(items)
        local f = items[1]
        require('perforated.picker.sources').revision(
          ws,
          { depotFile = f.depotFile },
          'Diff ' .. vim.fn.fnamemodify(f.depotFile, ':t') .. '#' .. f.rev .. ' against',
          function(r)
            local a, b = tonumber(r.rev), tonumber(f.rev)
            local this = { spec = f.depotFile .. '#' .. f.rev }
            local other = { spec = f.depotFile .. '#' .. r.rev }
            if a < b then -- older on the left
              require('perforated.revs').diff(ws, other, this)
            else
              require('perforated.revs').diff(ws, this, other)
            end
          end,
          f.rev
        )
      end,
    },
  }
end

local function node_for(view, c)
  local t = tonumber(c.time)
  local node = {
    id = 'sub:' .. c.change,
    kind = 'submitted',
    item = c,
    text = {
      { 'CL ' .. c.change, 'PerforatedChangelist' },
      { '  ' .. (t and os.date('%Y-%m-%d', t) or ''), 'PerforatedDim' },
      { ('  %-12s'):format(c.user or ''), 'PerforatedHeader' },
      { '  ' .. first_line(c.desc), 'PerforatedPath' },
    },
  }
  return M.expandable(view, node)
end

local function render(view)
  local roots = {}
  local title = ('Submitted changelists%s%s%s'):format(
    view.opts.user and (' · ' .. view.opts.user) or '',
    view.opts.path and (' · ' .. view.opts.path) or '',
    view.opts.anywhere and ' · all clients' or ''
  )
  roots[1] = { id = 'hdr', kind = 'header', text = { { title, 'PerforatedTitle' } } }
  for _, c in ipairs(view.changes) do
    roots[#roots + 1] = node_for(view, c)
  end
  if view.more then
    roots[#roots + 1] = {
      id = 'more',
      kind = 'more',
      text = { { view.loading and 'loading…' or '… more (gn)', 'PerforatedDim' } },
    }
  end
  view.tree:set(roots)
end

local function load_page(view)
  if view.loading or not view.more then
    return
  end
  view.loading = true
  view.gen = (view.gen or 0) + 1
  local gen = view.gen
  if vim.api.nvim_buf_is_valid(view.buf) then
    render(view) -- show "loading…" while the page is in flight
  end
  local oldest = view.changes[#view.changes]
  local page = view.opts.max or require('perforated.config').get().changes.page_size
  cls.submitted_changes(view.ws, {
    user = view.opts.user,
    path = view.opts.path,
    anywhere = view.opts.anywhere,
    max = page,
    before = oldest and (tonumber(oldest.change) - 1) or nil,
  }, function(changes, err)
    if gen ~= view.gen then
      return -- a refresh started over while this page was loading
    end
    view.loading = false
    if not changes then
      require('perforated.ui.toast').notify('[perforated] ' .. tostring(err), vim.log.levels.ERROR)
      changes = {}
    end
    vim.list_extend(view.changes, changes)
    view.more = #changes >= page
    if vim.api.nvim_buf_is_valid(view.buf) then
      render(view)
    end
  end)
end

--- Start over from the newest changelist (drops a page still in flight).
local function reload(view)
  view.changes, view.more, view.loading = {}, true, false
  view.gen = (view.gen or 0) + 1
  load_page(view)
end

local function actions(view)
  local ws = view.ws
  local list = {
    {
      id = 'expand',
      desc = 'Expand / collapse (files)',
      keys = { 'l', '<Tab>' },
      nomenu = true,
      run = function(_, ctx)
        if ctx.node and ctx.node.children then
          view.tree:toggle(ctx.node)
        end
      end,
    },
    {
      id = 'collapse',
      desc = 'Collapse',
      keys = { 'h', '<S-Tab>' },
      nomenu = true,
      run = function()
        view.tree:collapse_at_cursor()
      end,
    },
    {
      id = 'history',
      desc = 'File history',
      keys = { 'gh' },
      p4v = { '<C-t>' },
      kinds = { submitted_file = true },
      run = function(items)
        require('perforated.views.history').open(ws, items[1].depotFile)
      end,
    },
    {
      id = 'timelapse',
      desc = 'Time-lapse',
      keys = { 't' },
      p4v = { '<C-S-t>' },
      kinds = { submitted_file = true },
      when = function(item)
        return not require('perforated.history').deleted(item.action)
      end,
      run = function(items)
        local f = items[1]
        require('perforated.views.timelapse').open(ws, f.depotFile, { rev = tonumber(f.rev) })
      end,
    },
    {
      id = 'diff_all',
      desc = 'Diff all files',
      keys = { 'D', '<CR>' },
      p4v = { '<C-d>' },
      kinds = { submitted = true },
      footer = 10,
      run = function(items)
        require('perforated.diff.tab').open_change(ws, items[1])
      end,
    },
    {
      id = 'edit_description',
      desc = 'Edit description',
      keys = { 'i' }, -- as in the client view
      kinds = { submitted = true },
      footer = 20,
      when = function(item)
        return item.user == ws:user() or require('perforated.config').get().change.allow_force
      end,
      run = function(items)
        require('perforated.views.change_editor').edit(ws, items[1].change, {
          submitted = true,
          on_done = function(saved)
            if saved then
              reload(view)
            end
          end,
        })
      end,
    },
    {
      id = 'sync_to_change',
      desc = 'Sync workspace to this CL',
      keys = { 'g@' },
      kinds = { submitted = true },
      when = function()
        return ws.mode ~= 'connection'
      end,
      run = function(items)
        require('perforated.ops').sync_to_change(ws, items[1].change)
      end,
    },
    {
      id = 'integrate',
      desc = 'Integrate into this workspace',
      keys = { 'I' },
      kinds = { submitted = true },
      when = function()
        return ws.mode ~= 'connection'
      end,
      run = function(items)
        require('perforated.integrate').run(ws, items[1].change)
      end,
    },
    {
      id = 'describe',
      desc = 'Describe changelist',
      keys = { 'gd' },
      kinds = { submitted = true },
      nomenu = true, -- `K` covers it in the menu
      run = function(items)
        require('perforated.views.describe').open(ws, items[1].change)
      end,
    },
    {
      id = 'swarm_copy',
      desc = 'Copy Swarm URL',
      keys = { 'gX' },
      kinds = { submitted = true },
      when = function(item)
        return item and item.change ~= 'default'
      end,
      run = function(items)
        require('perforated.history').swarm(ws, items[1].change)
      end,
    },
    require('perforated.lookup').action(ws),
    {
      id = 'view_change',
      desc = 'View changelist',
      keys = { 'K' },
      kinds = { submitted = true, submitted_file = true }, -- on a file: its changelist
      footer = 12,
      run = function(items)
        require('perforated.views.change_info').open(ws, items[1])
      end,
    },
    {
      id = 'yank',
      desc = 'Copy CL number',
      keys = { 'y' },
      kinds = { submitted = true },
      run = function(items)
        vim.fn.setreg('"', items[1].change)
        pcall(vim.fn.setreg, '+', items[1].change)
      end,
    },
    {
      id = 'more',
      desc = 'Load more',
      keys = { 'gn' },
      nomenu = true,
      footer = 30,
      run = function()
        load_page(view)
      end,
    },
    {
      id = 'refresh',
      desc = 'Refresh',
      keys = { '<F5>' }, -- P4V's refresh key (as in the client view)
      nomenu = true,
      run = function()
        reload(view)
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      p4v = { '<C-w>' },
      nomenu = true,
      run = function()
        base.close(view)
      end,
    },
    {
      id = 'help',
      desc = 'Help',
      keys = { '?' },
      nomenu = true,
      run = function()
        keys.help(view.actions, 'Submitted changelists')
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
  return vim.list_extend(list, M.file_actions(ws))
end

---@param ws perforated.Workspace
---@param opts { user: string?, path: string?, max: integer? }?
function M.open(ws, opts)
  opts = opts or {}
  local buf, win =
    base.tab(('perforated://changes/%s'):format(opts.user or opts.path or ws:client() or ''))
  require('perforated.hl').setup()
  vim.b[buf].perforated_ws = ws.key
  local view = {
    ws = ws,
    buf = buf,
    win = win,
    opts = opts,
    changes = {},
    more = true,
    menu_layout = M.MENU_LAYOUT,
  }
  view.tree = require('perforated.ui.tree').new(buf)
  view.actions = actions(view)
  keys.attach(buf, view.actions, view)
  local footer = require('perforated.ui.footer').attach(win)
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      footer:set(keys.footer(view.actions, view.tree:node_at()))
      -- Reaching the last line loads the next page.
      if vim.fn.line('.') == vim.fn.line('$') and view.more then
        load_page(view)
      end
    end,
  })
  render(view)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].filetype = 'perforated'
    end
  end)
  footer:set(keys.footer(view.actions, nil))
  load_page(view)
  return view
end

M._actions = actions -- for the generated help (scripts/gen_doc.lua)

return M
