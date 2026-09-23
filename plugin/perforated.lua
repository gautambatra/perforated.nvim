-- perforated.nvim — Perforce integration for Neovim.
--
-- This file is deliberately tiny: it defines the :P4 commands, <Plug> maps and one autocmd.
-- The activation gate (lua/perforated/gate.lua) loads on the first file opened; everything else
-- only once a buffer inside a Perforce workspace is opened (or a :P4 command is run).
-- Outside Perforce the plugin costs one cached directory lookup per new directory.

if vim.g.loaded_perforated then
  return
end
vim.g.loaded_perforated = true

if vim.fn.has('nvim-0.11') == 0 then
  return
end

local group = vim.api.nvim_create_augroup('perforated', { clear = true })

local function on_buf(ev)
  require('perforated.gate').on_buf(ev)
end

vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
  group = group,
  desc = 'perforated: activate for buffers inside Perforce workspaces',
  callback = on_buf,
})

-- Lazy-loaded after startup (plugin managers): pick up buffers that are already open.
if vim.v.vim_did_enter == 1 then
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      on_buf({ buf = buf })
    end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Commands: `:P4 <sub> …` plus flat aliases (`:P4info`, …). Keep `subs` in sync with
-- lua/perforated/commands.lua (a test enforces it).
-- ---------------------------------------------------------------------------------------------

local subs = {
  'add',
  'annotate',
  'blame',
  'change',
  'changes',
  'debug',
  'describe',
  'diff',
  'dismiss',
  'edit',
  'filelog',
  'history',
  'hunks',
  'info',
  'log',
  'login',
  'lookup',
  'notifications',
  'opened',
  'pick',
  'refresh',
  'revert',
  'status',
  'view',
}

vim.api.nvim_create_user_command('P4', function(o)
  require('perforated.commands').run(o)
end, {
  nargs = '*',
  bang = true,
  range = true,
  desc = 'Perforce: :P4 <subcommand> [args]',
  complete = function(arglead, cmdline, pos)
    return require('perforated.commands').complete(arglead, cmdline, pos)
  end,
})

if vim.tbl_get(vim.g, 'perforated', 'commands', 'aliases') ~= false then
  for _, sub in ipairs(subs) do
    vim.api.nvim_create_user_command('P4' .. sub, function(o)
      require('perforated.commands').dispatch(sub, o)
    end, {
      nargs = '*',
      bang = true,
      range = true,
      desc = 'Perforce: :P4 ' .. sub,
      complete = function(arglead, cmdline, pos)
        return require('perforated.commands').complete_args(sub, arglead, cmdline, pos)
      end,
    })
  end
end

-- Depot revisions as buffers: `:e perforated:////depot/path/file.c#3`.
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('perforated.uri', { clear = true }),
  pattern = 'perforated:////*',
  callback = function(ev)
    require('perforated.uri').read(ev.buf)
  end,
})

-- <Plug>(perforated-…) mappings; nothing is loaded until one is used.
for _, name in ipairs({
  'next-hunk',
  'prev-hunk',
  'preview-hunk',
  'reset-hunk',
  'edit',
  'edit-prompt',
  'add',
  'revert',
  'diff',
  'diff-external',
  'hunks',
  'hunks-file',
  'opened',
  'status',
  'info',
  'log',
  'notifications',
  'history',
  'annotate',
  'blame-line',
  'describe',
  'lookup',
}) do
  vim.api.nvim_set_keymap(
    'n',
    '<Plug>(perforated-' .. name .. ')',
    "<Cmd>lua require('perforated.keymaps').run('" .. name .. "')<CR>",
    { noremap = true, desc = 'perforated: ' .. name }
  )
end
