-- A clean Neovim for screenshots and recordings of the demo workspace: this checkout of the
-- plugin, a theme, lualine and icons, nothing else. Started by scripts/demo/nvim.sh, which points
-- the XDG directories into .deps/demo-nvim, so plugins are installed there and nothing
-- touches your own config.
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    'git',
    'clone',
    '--filter=blob:none',
    '--branch=stable',
    'https://github.com/folke/lazy.nvim.git',
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = ' '
vim.o.number = true
vim.o.signcolumn = 'yes'
vim.o.termguicolors = true
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.laststatus = 3
vim.o.showtabline = 0 -- the default tabline shortens paths to /t/p/g/…
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. 'I'

require('lazy').setup({
  {
    'folke/tokyonight.nvim',
    priority = 1000,
    config = function()
      vim.cmd.colorscheme('tokyonight-night')
    end,
  },
  { 'nvim-tree/nvim-web-devicons' },
  {
    'nvim-lualine/lualine.nvim',
    config = function()
      require('lualine').setup({
        options = { globalstatus = true },
        sections = { lualine_c = { 'filename', 'perforated' }, lualine_x = { 'filetype' } },
      })
    end,
  },
  { dir = repo, name = 'perforated.nvim', opts = { keymaps = 'default' } },
}, {
  lockfile = vim.fn.stdpath('data') .. '/lazy-lock.json',
  install = { colorscheme = { 'tokyonight' } },
  change_detection = { enabled = false },
  rocks = { enabled = false },
})
