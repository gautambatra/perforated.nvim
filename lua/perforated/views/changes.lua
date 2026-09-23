--- `:P4 changes [-u user] [-m N] [path]`: submitted changelists, newest first, paginated.
---
--- Scoped to the client view by default (`path` overrides). `gn` / reaching the end loads the
--- next page (`path@<oldest-1>`), so no query is unbounded. Actions: D diff all files, C edit
--- description (own CLs), y copy, Q quickfix of the CL's files is left to the diff tab.

local p4 = require('perforated.p4')
local keys = require('perforated.ui.keys')

local M = {}

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

local function node_for(c)
  local t = tonumber(c.time)
  return {
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
end

local function render(view)
  local roots = {}
  local title = ('Submitted changelists%s%s'):format(
    view.opts.user and (' · ' .. view.opts.user) or '',
    view.opts.path and (' · ' .. view.opts.path) or ''
  )
  roots[1] = { id = 'hdr', kind = 'header', text = { { title, 'PerforatedTitle' } } }
  for _, c in ipairs(view.changes) do
    roots[#roots + 1] = node_for(c)
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
  if vim.api.nvim_buf_is_valid(view.buf) then
    render(view) -- show "loading…" while the page is in flight
  end
  local oldest = view.changes[#view.changes]
  local page = view.opts.max or require('perforated.config').get().changes.page_size
  p4.submitted_changes(view.ws, {
    user = view.opts.user,
    path = view.opts.path,
    max = page,
    before = oldest and (tonumber(oldest.change) - 1) or nil,
  }, function(changes, err)
    view.loading = false
    if not changes then
      vim.notify('[perforated] ' .. tostring(err), vim.log.levels.ERROR)
      changes = {}
    end
    vim.list_extend(view.changes, changes)
    view.more = #changes >= page
    if vim.api.nvim_buf_is_valid(view.buf) then
      render(view)
    end
  end)
end

---@param ws perforated.Workspace
---@param opts { user: string?, path: string?, max: integer? }?
function M.open(ws, opts)
  opts = opts or {}
  vim.cmd('tabnew')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    ('perforated://changes/%s'):format(opts.user or opts.path or ws:client() or '')
  )
  vim.wo.cursorline, vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn =
    true, false, false, 'no'
  require('perforated.hl').setup()
  local view = { ws = ws, buf = buf, opts = opts, changes = {}, more = true }
  view.tree = require('perforated.ui.tree').new(buf)
  view.actions = {
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
      keys = { 'C' },
      kinds = { submitted = true },
      footer = 20,
      when = function(item)
        return item.user == ws:user() or require('perforated.config').get().change.allow_force
      end,
      run = function(items)
        require('perforated.views.change_editor').edit(ws, items[1].change, {
          submitted = true,
          on_done = function()
            view.changes, view.more = {}, true
            load_page(view)
          end,
        })
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
      keys = { 'gr' },
      nomenu = true,
      run = function()
        view.changes, view.more = {}, true
        load_page(view)
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      p4v = { '<C-w>' },
      nomenu = true,
      run = function()
        vim.cmd('tabclose')
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
      keys = { '<Space>' },
      nomenu = true,
      run = function()
        keys.menu(view.actions, view)
      end,
    },
  }
  keys.attach(buf, view.actions, view)
  local footer = require('perforated.ui.footer').attach(vim.api.nvim_get_current_win())
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

return M
