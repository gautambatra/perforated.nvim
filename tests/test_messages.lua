-- Plugin messages: toasts by default (titled by level, wrapped), vim.notify with
-- toast.backend = 'notify'.
local H = require('tests.helpers')
local T = MiniTest.new_set()

local child

T['messages'] = MiniTest.new_set({
  hooks = {
    post_case = function()
      child.stop()
    end,
  },
})

T['messages']['are toasts titled by level; long lines wrap; errors get an error border'] = function()
  child = H.child({})
  child.o.columns = 80
  child.lua([[
    local toast = require('perforated.ui.toast')
    toast.notify('[perforated] created CL 12')
    toast.notify(('word '):rep(40), vim.log.levels.ERROR)
  ]])
  local shown = child.lua_get([[vim.tbl_map(function(t)
    return {
      title = t.title,
      height = vim.api.nvim_win_get_height(t.win),
      width = vim.api.nvim_win_get_width(t.win),
      hl = vim.wo[t.win].winhighlight,
      first = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(t.win), 0, 1, false)[1],
    }
  end, require('perforated.ui.toast').visible())]])
  H.eq(#shown, 2)
  H.eq(shown[1].title, 'Perforce')
  H.eq(shown[1].first, ' created CL 12 ') -- the [perforated] prefix is dropped
  H.eq(shown[1].hl:find('PerforatedToastInfoBorder', 1, true) ~= nil, true)
  H.eq(shown[2].title, 'Perforce: error')
  H.eq(shown[2].height > 1, true) -- wrapped, not cut off
  H.eq(shown[2].width <= 48, true)
  H.eq(shown[2].hl:find('PerforatedToastErrorBorder', 1, true) ~= nil, true)
  -- Kept in the :P4 notifications history.
  H.eq(child.lua_get([[#require('perforated.ui.toast').history()]]), 2)
end

T['messages']['confirmations are a pop-up menu: & letters, <CR> = default, <Esc> cancels'] = function()
  child = H.child({})
  child.lua([[vim.fn.confirm = function() _G.cmdline = true; return 1 end]])
  local function ask(keys)
    child.lua_notify(
      [[_G.r = require('perforated.ui.prompt').confirm('Delete CL 5?\nIts shelf goes too.', '&Delete\n&Cancel', 2)]]
    )
    vim.uv.sleep(100)
    child.type_keys(keys)
    return child.lua_get('_G.r')
  end
  H.eq(ask('<CR>'), 2)
  H.eq(ask('d'), 1)
  H.eq(ask('D'), 1)
  H.eq(ask('c'), 2)
  H.eq(ask('<Esc>'), 0)
  H.eq(child.lua_get('_G.cmdline'), vim.NIL) -- never the command line
  H.eq(child.lua_get([[require('perforated.ui.float').active]]), vim.NIL)
end

T['messages']['text input is a pop-up; empty and cancelled answers differ'] = function()
  child = H.child({})
  local function ask(keys)
    child.lua([[_G.r = 'unset'; require('perforated.ui.prompt').input(
      { prompt = 'Go to (CL number, path or user): ', default = '12' },
      function(v) _G.r = v == nil and 'nil' or v end)]])
    H.eq(child.bo.filetype, 'perforated-input')
    H.eq(child.api.nvim_win_get_config(0).title[1][1], ' Go to (CL number, path or user) ')
    child.type_keys(keys)
    H.eq(H.wait(child, [[_G.r ~= 'unset']]), true)
    H.eq(child.bo.filetype ~= 'perforated-input', true)
    return child.lua_get('_G.r')
  end
  H.eq(ask({ '3', '<CR>' }), '123')
  H.eq(ask({ '<C-u>', '<CR>' }), '')
  H.eq(ask('<Esc>'), 'nil')
end

T['messages']['jobs: a pop-up when they start and when they end, nothing in between'] = function()
  child = H.child({})
  child.lua([[
    _G.echo = 0
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(...) _G.echo = _G.echo + 1; return echo(...) end
    local progress = require('perforated.ui.progress')
    local p = progress.start('p4', 'sync…  (:P4 jobs to watch, :P4 cancel to stop)')
    progress.update(p, '10 files')
    progress.finish(p, 'synced 10 files')
  ]])
  H.eq(child.lua_get('_G.echo'), 0)
  H.eq(
    child.lua_get(
      [[vim.tbl_map(function(t) return t.lines[1] end, require('perforated.ui.toast').history())]]
    ),
    { 'p4: sync…  (:P4 jobs to watch, :P4 cancel to stop)', 'p4: synced 10 files' }
  )
end

T['messages']['a busy pop-up stays until closed and is not in the history'] = function()
  child = H.child({})
  child.lua([[_G.close = require('perforated.ui.toast').busy('Opening diff view…')]])
  child.type_keys('j') -- activity starts countdowns of normal toasts, not this one
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 1)
  H.eq(child.lua_get([[#require('perforated.ui.toast').history()]]), 0)
  child.lua([[_G.close()]])
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
end

T['messages']["toast.backend = 'notify' sends them to vim.notify"] = function()
  child = H.child({ config = { toast = { backend = 'notify' } } })
  child.lua([[
    _G.msgs = {}
    vim.notify = function(m, level) table.insert(_G.msgs, { m, level }) end
    require('perforated.ui.toast').notify('created CL 12')
    require('perforated.ui.toast').notify('[perforated] edit failed: locked', vim.log.levels.ERROR)
  ]])
  H.eq(child.lua_get('_G.msgs'), {
    { '[perforated] created CL 12', vim.log.levels.INFO },
    { '[perforated] edit failed: locked', vim.log.levels.ERROR },
  })
  H.eq(child.lua_get([[#require('perforated.ui.toast').visible()]]), 0)
  -- … and questions to Neovim's own confirm / vim.ui.input.
  child.lua([[
    vim.fn.confirm = function(msg, choices, default) _G.c = { msg, choices, default }; return 1 end
    vim.ui.input = function(opts, cb) _G.i = opts.prompt; cb('x') end
    _G.r1 = require('perforated.ui.prompt').confirm('Sure?', '&Yes\n&No', 2)
    require('perforated.ui.prompt').input({ prompt = 'Name: ' }, function(v) _G.r2 = v end)
  ]])
  H.eq(
    child.lua_get('{ _G.c, _G.r1, _G.i, _G.r2 }'),
    { { 'Sure?', '&Yes\n&No', 2 }, 1, 'Name: ', 'x' }
  )
end

return T
