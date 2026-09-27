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
end

return T
