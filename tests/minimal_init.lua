-- Minimal init for tests (both the test runner and child Neovim instances).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. '/.deps/mini.nvim')
package.path = ('%s/?.lua;%s/?/init.lua;'):format(root, root) .. package.path
vim.o.swapfile = false
vim.o.shadafile = 'NONE'
vim.g.perforated_test_root = root
