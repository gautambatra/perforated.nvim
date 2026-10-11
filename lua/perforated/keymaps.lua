--- `<Plug>` actions (defined cheaply in plugin/) and the opt-in buffer-local preset.
---
--- The preset (`keymaps = 'default'`) is installed only in buffers of Perforce workspaces,
--- so other buffers never see perforated mappings. File explorers (oil, netrw, …) showing a
--- directory inside a workspace get the part that needs no current file (`EXPLORER`).

local M = {}

local function cmd(name, args, bang)
  return function()
    require('perforated.commands').dispatch(name, { fargs = args or {}, bang = bang or false })
  end
end

--- name → function. `<Plug>(perforated-<name>)` calls these.
M.actions = {
  ['next-hunk'] = function()
    require('perforated.signs').nav(true, vim.v.count1)
  end,
  ['prev-hunk'] = function()
    require('perforated.signs').nav(false, vim.v.count1)
  end,
  ['preview-hunk'] = function()
    require('perforated.signs').preview()
  end,
  ['reset-hunk'] = function()
    require('perforated.signs').reset()
  end,
  edit = cmd('edit'),
  ['edit-prompt'] = function()
    require('perforated.checkout').prompt(vim.api.nvim_get_current_buf(), 'edit')
  end,
  add = cmd('add'),
  revert = cmd('revert'),
  diff = cmd('diff'),
  ['diff-external'] = cmd('diff', {}, true),
  hunks = cmd('hunks'),
  ['hunks-file'] = cmd('hunks', { '%' }),
  opened = cmd('opened'),
  status = cmd('status'),
  info = cmd('info'),
  log = cmd('log'),
  messages = cmd('messages'),
  history = cmd('filelog'),
  annotate = cmd('annotate'),
  ['blame-line'] = cmd('blame'),
  describe = cmd('describe'),
  lookup = cmd('lookup'),
  sync = cmd('sync'),
  ['sync-file'] = cmd('sync', { '%' }),
  resolve = cmd('resolve', { '%' }),
  submit = cmd('submit'),
  shelve = cmd('shelve'),
  timelapse = cmd('timelapse'),
  view = cmd('view'), -- the client view (`:P4`)
}

--- Preset: lhs → action name.
M.PRESET = {
  ['<leader>pp'] = 'view',
  [']h'] = 'next-hunk',
  ['[h'] = 'prev-hunk',
  ['<leader>pv'] = 'preview-hunk',
  ['<leader>pu'] = 'reset-hunk',
  ['<leader>pe'] = 'edit-prompt',
  ['<leader>pa'] = 'add',
  ['<leader>pr'] = 'revert',
  ['<leader>pd'] = 'diff',
  ['<leader>pD'] = 'diff-external',
  ['<leader>pq'] = 'hunks',
  ['<leader>pQ'] = 'hunks-file',
  ['<leader>po'] = 'opened',
  ['<leader>ps'] = 'status',
  ['<leader>pi'] = 'info',
  ['<leader>pl'] = 'log',
  ['<leader>pm'] = 'messages',
  ['<leader>ph'] = 'history',
  ['<leader>pA'] = 'annotate',
  ['<leader>pb'] = 'blame-line',
  ['<leader>pc'] = 'describe',
  ['<leader>pg'] = 'lookup',
  ['<leader>py'] = 'sync-file',
  ['<leader>pY'] = 'sync',
  ['<leader>pR'] = 'resolve',
  ['<leader>pP'] = 'submit',
  ['<leader>pS'] = 'shelve',
  ['<leader>pt'] = 'timelapse',
}

---@param name string
function M.run(name)
  local fn = M.actions[name]
  if fn then
    fn()
  end
end

--- Preset actions that need no current file: the ones a file explorer buffer gets.
M.EXPLORER = {
  view = true,
  opened = true,
  status = true,
  info = true,
  log = true,
  messages = true,
  hunks = true, -- all opened files
  lookup = true,
  sync = true, -- the whole workspace
}

--- Install the preset in a Perforce buffer (when enabled). User buffer-local maps win.
---@param buf integer
---@param only table<string, true>?  action names to map (default: the whole preset)
function M.attach(buf, only)
  if require('perforated.config').get().keymaps ~= 'default' then
    return
  end
  -- maparg() looks at the current buffer, and buffers are also attached in the background.
  local function install()
    for lhs, name in pairs(M.PRESET) do
      if (not only or only[name]) and vim.fn.maparg(lhs, 'n', false, true).buffer ~= 1 then
        vim.keymap.set('n', lhs, '<Plug>(perforated-' .. name .. ')', {
          buffer = buf,
          remap = true,
          desc = 'perforated: ' .. name,
        })
      end
    end
  end
  if buf == 0 or buf == vim.api.nvim_get_current_buf() then
    install()
  else
    vim.api.nvim_buf_call(buf, install)
  end
end

--- A file explorer buffer (FileType oil, netrw, minifiles, NvimTree, neo-tree; plugin/): the
--- `EXPLORER` keys when the directory it shows (oil, netrw; a tree
--- explorer: the cwd) is inside a workspace.
---@param buf integer
function M.attach_explorer(buf)
  if require('perforated.config').get().keymaps ~= 'default' then
    return
  end
  local dir = require('perforated.core.workspace').buf_dir(buf)
  require('perforated.core.activation').resolve(dir, function(ws)
    if ws and vim.api.nvim_buf_is_valid(buf) then
      M.attach(buf, M.EXPLORER)
    end
  end)
end

return M
