-- Commands that change files: no call timeout, Ctrl+c on their pop-up, and one warning however
-- they were stopped.
local H = require('tests.helpers')
local T = MiniTest.new_set()

local child, root

local function setup(rules, config)
  root = H.tmp()
  H.write(root .. '/.p4config', 'P4PORT=fake:1666\n')
  H.write(root .. '/a.c', 'a\n')
  H.write(root .. '/b.c', 'b\n')
  vim.list_extend(rules, { { match = '.', records = {} } })
  child = H.child({
    fake = { rules = rules },
    env = { P4CONFIG = '.p4config' },
    config = vim.tbl_extend('force', { p4 = H.fake_p4 }, config or {}),
  })
  child.lua(([[
    _G.ws = require('perforated.core.activation').for_dir(%q)
    _G.root = %q
    _G.co = require('perforated.checkout')
    _G.toast = require('perforated.ui.toast')
    _G.jobs = require('perforated.jobs')
    _G.popup = function()
      local out = {}
      for _, t in ipairs(_G.toast.visible()) do
        if t.busy then
          out[#out + 1] = t.lines
        end
      end
      return out
    end
    _G.ctrl_c = function()
      return vim.fn.maparg('<C-c>', 'n')
    end
  ]]):format(root, root))
end

local function wait_popup(n)
  H.wait(child, ('#_G.popup() == %d'):format(n or 1))
end

--- Start a hanging revert of `files` and wait for its pop-up.
local function hang_revert(files)
  child.lua(([[
    local paths = vim.tbl_map(function(f) return _G.root .. '/' .. f end, %s)
    _G.co.revert(_G.ws, paths, false, function(ok) _G.done = { ok = ok } end)
  ]]):format(vim.inspect(files)))
  wait_popup()
end

T['cancel'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['cancel']['a change that outlasts runner.timeout is not killed'] = function()
  setup({
    { match = '^revert', sleep = 1, records = { { clientFile = 'a.c', action = 'reverted' } } },
  }, { runner = { timeout = 200 } })
  child.lua([[_G.co.revert(_G.ws, { _G.root .. '/a.c' }, false, function(ok) _G.ok = ok end)]])
  H.wait(child, '_G.ok ~= nil')
  H.eq(H.wait_message(child, 'revert: 1 file(s)', 1000), true)
  H.eq(H.messages(child):find('timed out', 1, true), nil)
end

T['cancel']['Ctrl+c on the pop-up stops the command and warns, then gives the key back'] = function()
  setup({ { match = '^revert', hang = true } })
  hang_revert({ 'a.c' })
  H.eq(child.lua_get('_G.popup()'), { { 'Reverting a.c…', 'Ctrl+c to cancel' } })
  child.type_keys('<C-c>')
  H.wait(child, '_G.done ~= nil')
  H.eq(H.wait_message(child, 'revert cancelled: the file may already be reverted', 1000), true)
  H.eq(child.lua_get('_G.popup()'), {})
  H.eq(child.lua_get('_G.ctrl_c()'), '')
  H.eq(child.lua_get('#_G.jobs.list()'), 0)
  H.eq(H.messages(child):find('revert failed', 1, true), nil)
  H.eq(child.lua_get([[require('perforated.ui.toast').history()[#_G.toast.history()].level]]), 3)
end

T['cancel'][':P4 cancel gives the same warning'] = function()
  setup({ { match = '^revert', hang = true } })
  hang_revert({ 'a.c', 'b.c' })
  child.lua('_G.jobs.cancel()')
  H.wait(child, '_G.done ~= nil')
  H.eq(H.wait_message(child, 'revert cancelled: some files may already be reverted', 1000), true)
  H.eq(child.lua_get('_G.ctrl_c()'), '')
end

T['cancel']['the key stops the newest pop-up only'] = function()
  setup({
    { match = '^revert', hang = true },
    { match = '^add', hang = true },
  })
  hang_revert({ 'a.c' })
  child.lua([[_G.co.add(_G.ws, { _G.root .. '/b.c' }, nil, function() _G.added = true end)]])
  wait_popup(2)
  child.type_keys('<C-c>')
  H.wait(child, '_G.added == true')
  H.eq(child.lua_get('_G.done'), vim.NIL)
  H.eq(child.lua_get('_G.popup()'), { { 'Reverting a.c…', 'Ctrl+c to cancel' } })
  child.type_keys('<C-c>')
  H.wait(child, '_G.done ~= nil')
end

T['cancel']["the user's own Ctrl+c mapping comes back"] = function()
  setup({ { match = '^revert', hang = true } })
  child.lua([[vim.keymap.set('n', '<C-c>', function() _G.mine = true end, { desc = 'mine' })]])
  hang_revert({ 'a.c' })
  child.type_keys('<C-c>')
  H.wait(child, '_G.done ~= nil')
  H.eq(child.lua_get('_G.mine'), vim.NIL)
  child.type_keys('<C-c>')
  H.eq(child.lua_get('_G.mine'), true)
end

T['cancel']['a buffer-local Ctrl+c (prompts, pickers) keeps working'] = function()
  setup({ { match = '^revert', hang = true } })
  child.lua([[vim.keymap.set('n', '<C-c>', function() _G.mine = true end, { buffer = 0 })]])
  hang_revert({ 'a.c' })
  child.type_keys('<C-c>')
  H.eq(child.lua_get('_G.mine'), true)
  H.eq(child.lua_get('_G.done'), vim.NIL)
  child.lua('_G.jobs.cancel()')
  H.wait(child, '_G.done ~= nil')
end

T['cancel']['no key and no hint with the vim.notify backend'] = function()
  setup({ { match = '^revert', hang = true } }, { toast = { backend = 'notify' } })
  child.lua([[_G.co.revert(_G.ws, { _G.root .. '/a.c' }, false, function() _G.done = true end)]])
  H.wait(child, '#_G.jobs.list() == 1')
  H.eq(child.lua_get('_G.ctrl_c()'), '')
  H.eq(H.messages(child):find('Ctrl+c', 1, true), nil)
  child.lua('_G.jobs.cancel()')
  H.wait(child, '_G.done == true')
end

T['cancel']['a stopped checkout puts the file back to read-only'] = function()
  setup({ { match = '^edit', hang = true } })
  child.lua([[
    vim.uv.fs_chmod(_G.root .. '/a.c', tonumber('444', 8))
    _G.co.edit(_G.ws, { _G.root .. '/a.c' }, nil, function(ok) _G.ok = ok end)
  ]])
  wait_popup()
  H.eq(child.lua_get([[vim.fn.filewritable(_G.root .. '/a.c')]]), 1)
  child.type_keys('<C-c>')
  H.wait(child, '_G.ok ~= nil')
  H.eq(child.lua_get('_G.ok'), false)
  H.eq(child.lua_get([[vim.fn.filewritable(_G.root .. '/a.c')]]), 0)
  H.eq(H.wait_message(child, 'edit cancelled: the file may already be opened', 1000), true)
end

T['cancel']['moving files shows a pop-up only when it takes a while'] = function()
  setup({
    { match = '^reopen %-c 1', records = { { clientFile = 'a.c' } } },
    { match = '^reopen %-c 2', hang = true },
  })
  child.lua([[
    require('perforated.changelists').reopen(_G.ws, { _G.root .. '/a.c' }, '1', function(res)
      _G.quick = res.ok
    end)
    local busy = _G.toast.busy
    _G.toast.busy = function(...) _G.flashed = true; return busy(...) end
  ]])
  H.wait(child, '_G.quick == true')
  child.lua('vim.wait(600, function() return false end)')
  H.eq(child.lua_get('_G.flashed'), vim.NIL)
  child.lua([[
    require('perforated.changelists').reopen(_G.ws, { _G.root .. '/a.c' }, '2', function(res)
      _G.stopped = res.stopped
    end)
  ]])
  H.eq(child.lua_get('_G.popup()'), {})
  wait_popup()
  H.eq(child.lua_get('_G.popup()'), { { 'Moving 1 file(s)…', 'Ctrl+c to cancel' } })
  child.type_keys('<C-c>')
  H.wait(child, '_G.stopped == true')
  H.eq(H.wait_message(child, 'reopen cancelled: the file may already be moved', 1000), true)
end

T['cancel']['a busy task offers Ctrl+c without reopening its pop-up'] = function()
  setup({
    { match = '^shelve', hang = true },
    { match = '^describe', records = { { change = '5', status = 'pending' } } },
  })
  child.lua([[
    local busy = _G.toast.busy
    _G.opened = 0
    _G.toast.busy = function(...) _G.opened = _G.opened + 1; return busy(...) end
    require('perforated.ops').shelve(_G.ws, '5', nil, function(ok) _G.ok = ok end)
  ]])
  H.wait(child, [[_G.popup()[1] and _G.popup()[1][2] == 'Ctrl+c to cancel']])
  H.eq(child.lua_get('_G.opened'), 1)
  H.eq(child.lua_get('#_G.toast.visible()'), 1)
  child.type_keys('<C-c>')
  H.wait(child, '_G.ok ~= nil')
  H.eq(child.lua_get('_G.ok'), false)
  H.eq(H.wait_message(child, 'shelve cancelled: some files may already be shelved', 1000), true)
end

T['cancel']['deleting shelved files can be cancelled'] = function()
  setup({ { match = '^shelve %-d', hang = true } }, { runner = { timeout = 200 } })
  child.lua([[
    require('perforated.ui.prompt').confirm = function() return 1 end
    require('perforated.ops').delete_shelved(_G.ws, '5', nil, function(ok) _G.ok = ok end)
  ]])
  wait_popup()
  H.eq(child.lua_get('_G.popup()'), { { 'Deleting shelved files of CL 5…', 'Ctrl+c to cancel' } })
  child.lua('vim.wait(400, function() return false end)') -- past runner.timeout: not killed
  H.eq(child.lua_get('_G.ok'), vim.NIL)
  child.type_keys('<C-c>')
  H.wait(child, '_G.ok ~= nil')
  H.eq(child.lua_get('_G.ok'), false)
  H.eq(
    H.wait_message(
      child,
      'shelve cancelled: some files may already be deleted from the shelf',
      1000
    ),
    true
  )
  H.eq(H.messages(child):find('deleted shelved files', 1, true), nil)
end

T['cancel']['a cancelled submit says it may still have gone through'] = function()
  setup({ { match = '^submit', hang = true } })
  child.lua([[
    require('perforated.ops').run_submit(_G.ws, '5', nil, function(ok) _G.ok = ok end, {})
  ]])
  H.wait(child, [[_G.popup()[1] and _G.popup()[1][2] == 'Ctrl+c to cancel']])
  child.type_keys('<C-c>')
  H.wait(child, '_G.ok ~= nil')
  H.eq(child.lua_get('_G.ok'), false)
  H.eq(
    H.wait_message(child, 'submit cancelled: it may still have gone through, check CL 5', 1000),
    true
  )
end

T['cancel']['p4 dying without a message reports its exit code'] = function()
  setup({ { match = '^revert', kill = 'sigkill' } })
  child.lua([[_G.co.revert(_G.ws, { _G.root .. '/a.c' }, false, function() _G.done = true end)]])
  H.wait(child, '_G.done == true')
  H.eq(H.wait_message(child, 'revert failed: p4 exited with code 137', 1000), true)
  H.eq(H.messages(child):find('unknown error', 1, true), nil)
end

-- A sync streams a record per file; the first carries p4's totals.
local SYNC = {
  {
    depotFile = '//d/a.c',
    action = 'updated',
    fileSize = '1024',
    totalFileCount = '4',
    totalFileSize = '4096',
  },
  { depotFile = '//d/b.c', action = 'updated', fileSize = '1024' },
}

T['cancel']['a sync shows files and bytes out of its totals, and a percentage'] = function()
  setup({ { match = '^sync', records = SYNC, hang_after = true } })
  child.lua([[
    _G.pcts = {}
    local progress = require('perforated.ui.progress')
    local update = progress.update
    progress.update = function(p, msg, pct) table.insert(_G.pcts, pct or false); return update(p, msg, pct) end
    require('perforated.ops')._run_sync(_G.ws, {}, 'workspace', nil, false, function() end)
  ]])
  H.wait(child, '#_G.jobs.list() == 1 and _G.jobs.list()[1].files == 2')
  child.cmd('P4 jobs')
  local line = child.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  H.neq(line:find('sync workspace · %d+s · 2/4 files %(50%%%) · 2%.0/4%.0 KB'), nil)
  H.wait(child, '#_G.pcts > 0')
  H.eq(child.lua_get('_G.pcts[#_G.pcts]'), 50)
  child.lua('_G.jobs.cancel()')
  H.wait(child, '#_G.jobs.list() == 0')
end

T['cancel']['a job without totals shows its plain count'] = function()
  setup({
    {
      match = '^sync',
      records = { { depotFile = '//d/a.c', action = 'updated' } },
      hang_after = true,
    },
  })
  child.lua(
    [[require('perforated.ops')._run_sync(_G.ws, {}, 'workspace', nil, false, function() end)]]
  )
  H.wait(child, '#_G.jobs.list() == 1 and _G.jobs.list()[1].count == 1')
  child.cmd('P4 jobs')
  local line = child.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  H.neq(line:find('sync workspace · %d+s · 1 file%(s%)'), nil)
  H.eq(line:find('%', 1, true), nil)
  child.lua('_G.jobs.cancel()')
  H.wait(child, '#_G.jobs.list() == 0')
end

return T
