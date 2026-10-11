-- Stacked pop-ups (ui/stack.lua): the one in use gets the accent border, the ones under it
-- are dimmed (a highlight namespace), and nothing changes without a pop-up in use.
local H = require('tests.helpers')
local T = MiniTest.new_set()

local child

T['stack'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = H.child({})
      child.o.termguicolors = true
      child.lua([[
        vim.api.nvim_set_hl(0, 'NormalFloat', { fg = '#ffffff', bg = '#000000' })
        vim.api.nvim_set_hl(0, 'FloatTitle', { fg = '#ff8800' })
        -- (A window without its own namespace reports 'winhighlight''s internal one, not 0.)
        _G.dimmed = function(win)
          return vim.api.nvim_get_hl_ns({ winid = win }) == vim.api.nvim_get_namespaces()['perforated.stack.dim']
        end
        _G.st = function(win) return require('perforated.ui.stack').state(win) end
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['stack']['history pop-up, then the lookup on top: the lookup stands out, history steps back'] = function()
  child.lua([[_G.hist_buf, _G.hist = require('perforated.views.base').float('history', 'History')]])
  H.eq(child.lua_get('_G.st(_G.hist)'), 'active')
  H.eq(child.lua_get('_G.dimmed(_G.hist)'), false)
  H.neq(
    child
      .lua_get([[vim.wo[_G.hist].winhighlight]])
      :find('FloatBorder:PerforatedFloatBorderActive', 1, true),
    nil
  )
  -- Ctrl+G's prompt.
  child.lua(
    [[require('perforated.ui.prompt').input({ prompt = 'Go to: ' }, function(v) _G.answer = v or 'nil' end)]]
  )
  local prompt = child.api.nvim_get_current_win()
  H.eq(child.lua_get('_G.st(...)', { prompt }), 'active')
  H.eq(child.lua_get('_G.st(_G.hist)'), 'dim')
  H.eq(child.lua_get('_G.dimmed(_G.hist)'), true)
  local dim = child.lua_get([[vim.api.nvim_get_namespaces()['perforated.stack.dim'] ]])
  -- Dimmed: the text halfway to the background (also the plugin's own groups), border fainter.
  local hl = function(name)
    return child.lua_get(('vim.api.nvim_get_hl(%d, { name = %q })'):format(dim, name))
  end
  H.eq(hl('NormalFloat').fg, 0x737373) -- #ffffff 55 % of the way to #000000
  H.eq(hl('NormalFloat').bg, 0x000000)
  H.eq(hl('PerforatedTitle').fg, 0x737373)
  H.eq(hl('PerforatedTitle').bg, nil)
  H.eq(hl('FloatBorder').fg, 0x404040)
  -- Done with the lookup: history is in use again.
  child.type_keys('<Esc>')
  H.eq(H.wait(child, [[_G.answer ~= nil and _G.st(_G.hist) == 'active']]), true)
  H.eq(child.lua_get('_G.dimmed(_G.hist)'), false)
end

T['stack']['an action menu (never focused) is the active one while it is open'] = function()
  child.lua([[_G.hist_buf, _G.hist = require('perforated.views.base').float('history', 'History')]])
  child.lua_notify(
    [[_G.pick = require('perforated.ui.float').menu({
    title = 'Actions', items = { { key = 'a', label = 'one' }, { key = 'b', label = 'two' } } })]]
  )
  H.eq(H.wait(child, [[require('perforated.ui.float').active ~= nil]]), true)
  H.eq(child.lua_get('_G.st(_G.hist)'), 'dim')
  H.eq(child.api.nvim_get_current_win(), child.lua_get('_G.hist')) -- focus never moved
  child.type_keys('<Esc>')
  H.eq(H.wait(child, [[require('perforated.ui.float').active == nil]]), true)
  H.eq(child.lua_get('_G.st(_G.hist)'), 'active')
end

T['stack']['no pop-up in use (cursor in a normal window): the usual look'] = function()
  child.lua([[_G.hist_buf, _G.hist = require('perforated.views.base').float('history', 'History')]])
  child.cmd('wincmd p') -- back to the editing window, the pop-up stays open
  H.eq(child.lua_get('_G.st(_G.hist)'), 'plain')
  H.eq(child.lua_get('_G.dimmed(_G.hist)'), false)
  H.eq(
    child.lua_get([[vim.wo[_G.hist].winhighlight]]),
    'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  )
end

T['stack']["the plugin's picker: filter, list and preview are one pop-up"] = function()
  child.lua([[_G.hist_buf, _G.hist = require('perforated.views.base').float('history', 'History')]])
  child.lua([[require('perforated.config').set({ picker = 'perforated' })
    require('perforated.picker').pick({
      title = 'Pick', items = { 'a', 'b' }, format = function(s) return s end,
      preview = function(s) return { s } end, on_choice = function() end })]])
  local p = [[require('perforated.picker.list')._active]]
  H.eq(child.lua_get(('_G.st(%s.list_win)'):format(p)), 'active')
  H.eq(child.lua_get(('_G.st(%s.prev_win)'):format(p)), 'active') -- not dimmed by its own list
  H.eq(child.lua_get('_G.st(_G.hist)'), 'dim')
end

return T
