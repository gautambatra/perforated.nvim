--- `<Plug>` actions (defined cheaply in plugin/) and the opt-in buffer-local preset.
---
--- The preset (`keymaps = 'default'`) is installed only in buffers of Perforce workspaces,
--- so other buffers never see perforated mappings.

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
  notifications = cmd('notifications'),
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
}

--- Preset: lhs → action name.
M.PRESET = {
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
  ['<leader>pn'] = 'notifications',
  ['<leader>pL'] = 'history',
  ['<leader>pb'] = 'annotate',
  ['<leader>pB'] = 'blame-line',
  ['<leader>pc'] = 'describe',
  ['<leader>pg'] = 'lookup',
  ['<leader>py'] = 'sync-file',
  ['<leader>pY'] = 'sync',
  ['<leader>pR'] = 'resolve',
  ['<leader>pP'] = 'submit',
  ['<leader>pz'] = 'shelve',
}

---@param name string
function M.run(name)
  local fn = M.actions[name]
  if fn then
    fn()
  end
end

--- Install the preset in a Perforce buffer (when enabled). User buffer-local maps win.
---@param buf integer
function M.attach(buf)
  if require('perforated.config').get().keymaps ~= 'default' then
    return
  end
  for lhs, name in pairs(M.PRESET) do
    if vim.fn.maparg(lhs, 'n', false, true).buffer ~= 1 then
      vim.keymap.set('n', lhs, '<Plug>(perforated-' .. name .. ')', {
        buffer = buf,
        remap = true,
        desc = 'perforated: ' .. name,
      })
    end
  end
end

return M
