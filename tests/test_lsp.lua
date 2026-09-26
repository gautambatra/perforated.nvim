-- Experimental LSP code actions (real p4d).
local H = require('tests.helpers')
local P = require('tests.helpers.p4d')
local T = MiniTest.new_set()

local child, server, root

T['lsp'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not P.available() then
        MiniTest.skip('p4/p4d not available (make deps)')
      end
      server = P.new()
      root = server.dir .. '/ws'
      server:client('alice_ws', root)
      server:submit_files('alice_ws', root, { ['a.txt'] = 'a\nb\nc\n' }, 'initial')
      server:p4config(root, 'alice_ws')
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local function titles()
  return child.lua_get([[(function()
    local res = vim.lsp.buf_request_sync(0, 'textDocument/codeAction', {
      textDocument = { uri = vim.uri_from_bufnr(0) },
      range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } },
      context = { diagnostics = {} },
    }, 3000)
    local out = {}
    for _, r in pairs(res or {}) do
      for _, a in ipairs(r.result or {}) do out[#out + 1] = a.title end
    end
    return out
  end)()]])
end

T['lsp']['off by default: no client'] = function()
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = { p4 = P.p4, poll = { interval = 0 }, startup_check = false },
  })
  child.cmd('edit ' .. root .. '/a.txt')
  H.eq(H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000), true)
  H.eq(child.lua_get([[#vim.lsp.get_clients({ name = 'perforated' })]]), 0)
end

T['lsp']['code actions follow the file state; running one works'] = function()
  child = H.child({
    env = { P4CONFIG = '.p4config' },
    config = {
      p4 = P.p4,
      poll = { interval = 0 },
      startup_check = false,
      checkout = { prompt = false },
      lsp = { enabled = true },
    },
  })
  child.cmd('edit ' .. root .. '/a.txt')
  H.eq(H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']], 15000), true)
  H.eq(H.wait(child, [[#vim.lsp.get_clients({ name = 'perforated', bufnr = 0 }) == 1]], 5000), true)
  local t = titles()
  H.eq(vim.tbl_contains(t, 'Perforce: check out (open for edit)'), true)
  H.eq(vim.tbl_contains(t, 'Perforce: file history'), true)
  H.eq(vim.tbl_contains(t, 'Perforce: revert'), false)
  -- open it and change line 2: diff / revert / hunk actions appear
  child.cmd('P4 edit')
  H.eq(
    H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'opened']], 15000),
    true
  )
  child.lua([[vim.bo.readonly = false]])
  child.api.nvim_buf_set_lines(0, 1, 2, false, { 'B' })
  H.eq(H.wait(child, [[#require('perforated.buffer').get().hunks == 1]], 5000), true)
  t = titles()
  H.eq(vim.tbl_contains(t, 'Perforce: diff against have revision'), true)
  H.eq(vim.tbl_contains(t, 'Perforce: undo this change (reset hunk)'), true)
  H.eq(vim.tbl_contains(t, 'Perforce: check out (open for edit)'), false)
  -- run "reset hunk" the way `gra` would (client-side command)
  child.lua(
    [[vim.lsp.commands['perforated.reset_hunk']({ command = 'perforated.reset_hunk', arguments = { vim.api.nvim_get_current_buf(), 2 } }, {})]]
  )
  H.eq(child.api.nvim_buf_get_lines(0, 1, 2, false), { 'b' })
end

return T
