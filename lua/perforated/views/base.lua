--- Shared scaffolding for tree views (describe, history): the window (tab or float), the
--- standard navigation actions, the key footer and `filetype` after the first paint.

local keys = require('perforated.ui.keys')

local M = {}

local function scratch(buf, name)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
end

local function win_opts(win)
  vim.wo[win].cursorline, vim.wo[win].number, vim.wo[win].relativenumber = true, false, false
  vim.wo[win].signcolumn, vim.wo[win].wrap, vim.wo[win].foldcolumn = 'no', false, '0'
end

--- A view buffer in a new tab.
---@param name string
---@return integer buf, integer win
function M.tab(name)
  vim.cmd('tabnew')
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  scratch(buf, name)
  win_opts(win)
  return buf, win
end

--- A view buffer in a centred float.
---@param name string
---@param title string
---@param size { width: number, height: number }?  fractions of the editor
---@return integer buf, integer win
function M.float(name, title, size)
  size = size or { width = 0.8, height = 0.6 }
  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf, name)
  local width = math.max(40, math.floor(vim.o.columns * size.width))
  local height = math.max(5, math.floor(vim.o.lines * size.height))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'left',
  })
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  win_opts(win)
  return buf, win
end

--- Standard navigation actions (fold, refresh, close, help, menu).
---@param view table  { tree, actions, close?, refresh? }
---@param title string
---@param opts { expand_menu: boolean? }?  `<CR>` on a leaf opens the action menu
---@return perforated.Action[]
function M.nav(view, title, opts)
  opts = opts or {}
  return {
    {
      id = 'expand',
      desc = 'Expand / toggle',
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
      id = 'refresh',
      desc = 'Refresh',
      keys = { 'gr' },
      nomenu = true,
      run = function()
        if view.refresh then
          view.refresh()
        end
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
        keys.help(view.actions, title)
      end,
    },
    {
      id = 'menu',
      desc = 'Action menu',
      keys = opts.expand_menu and { '.', '<RightMouse>', '<CR>' } or { '.', '<RightMouse>' },
      nomenu = true,
      run = function()
        keys.menu(view.actions, view)
      end,
    },
  }
end

--- Close a view's window (its tab when it has one of its own).
---@param view table
function M.close(view)
  if not vim.api.nvim_win_is_valid(view.win) then
    return
  end
  if vim.api.nvim_win_get_config(view.win).relative ~= '' then
    return vim.api.nvim_win_close(view.win, true)
  end
  if #vim.api.nvim_tabpage_list_wins(0) == 1 and #vim.api.nvim_list_tabpages() > 1 then
    return vim.cmd('tabclose')
  end
  vim.api.nvim_win_close(view.win, true)
end

--- Install keys and the footer (a float footer uses the window's own border footer).
---@param view table  { buf, win, tree, actions }
function M.finish(view)
  vim.b[view.buf].perforated_ws = view.ws.key
  keys.attach(view.buf, view.actions, view)
  local float = vim.api.nvim_win_get_config(view.win).relative ~= ''
  local footer = not float and require('perforated.ui.footer').attach(view.win) or nil
  local function update()
    local chunks = keys.footer(view.actions, view.tree:node_at())
    if footer then
      footer:set(chunks)
    elseif vim.api.nvim_win_is_valid(view.win) then
      pcall(vim.api.nvim_win_set_config, view.win, { footer = chunks, footer_pos = 'right' })
    end
  end
  view.update_footer = update
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = view.buf, callback = update })
  update()
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(view.buf) then
      vim.bo[view.buf].filetype = 'perforated'
    end
  end)
end

--- `p4` date → "YYYY-MM-DD".
---@param t string|number|nil
---@return string
function M.date(t)
  t = tonumber(t)
  return t and os.date('%Y-%m-%d', t) or ''
end

---@param s string?
---@return string
function M.first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

--- Map a buffer line to the base line it came from, given the buffer's hunks against the base
--- (nil: the line was added or changed locally).
---@param hunks perforated.Hunk[]
---@param lnum integer
---@return integer?
function M.base_line(hunks, lnum)
  local delta = 0
  for _, h in ipairs(hunks) do
    if h.b_count > 0 then
      if lnum >= h.b_start and lnum < h.b_start + h.b_count then
        return nil
      end
      if lnum >= h.b_start + h.b_count then
        delta = delta + h.a_count - h.b_count
      end
    elseif lnum > h.b_start then
      delta = delta + h.a_count
    end
  end
  return lnum + delta
end

return M
