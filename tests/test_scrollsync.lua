-- Scroll-bound plugin windows (diff sides, annotate) follow a scroll of the window that isn't
-- current: the mouse wheel scrolls the window under the pointer, and Neovim only syncs
-- 'scrollbind' windows when the current one scrolls.
local H = require('tests.helpers')
local T = MiniTest.new_set()

local child

T['scrollsync'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = H.child({})
      child.o.lines, child.o.columns = 30, 120
      child.o.mouse = 'a'
      child.lua([[
        local function buf(lines)
          local b = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
          return b
        end
        local a, b = {}, {}
        for i = 1, 300 do
          a[i], b[i] = 'line ' .. i, i % 7 == 0 and ('changed ' .. i) or ('line ' .. i)
        end
        vim.api.nvim_win_set_buf(0, buf(a))
        _G.left = vim.api.nvim_get_current_win()
        vim.cmd('vsplit')
        _G.right = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(_G.right, buf(b))
        -- as a redraw sees it: line('w0') brings the view up to date, scrolling back to the
        -- cursor if it was left out of view (a headless redraw doesn't)
        _G.top = function(w)
          return vim.api.nvim_win_call(w, function() return vim.fn.line('w0') end)
        end
        -- the wheel over a window: its middle, on the screen grid
        _G.wheel = function(w, dir)
          local pos = vim.api.nvim_win_get_position(w)
          vim.api.nvim_input_mouse('wheel', dir, '', 0, pos[1] + 5, pos[2] + 5)
        end
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T['scrollsync']['diff: the mouse wheel over the other side scrolls both'] = function()
  child.lua([[require('perforated.diff.view').diffthis({ _G.left, _G.right })]])
  child.api.nvim_set_current_win(child.lua_get('_G.right'))
  child.lua([[_G.wheel(_G.left, 'down')]])
  H.eq(H.wait(child, [[_G.top(_G.left) > 1]]), true)
  H.eq(H.wait(child, [[_G.top(_G.right) > 1 and _G.top(_G.right) == _G.top(_G.left)]]), true)
  -- the current side's cursor came along (in view), so the next redraw doesn't scroll it back
  local cur = child.api.nvim_win_get_cursor(child.lua_get('_G.right'))[1]
  H.eq(cur >= child.lua_get('_G.top(_G.right)'), true)
  child.lua([[_G.wheel(_G.left, 'up')]])
  H.eq(H.wait(child, [[_G.top(_G.left) == 1 and _G.top(_G.right) == 1]]), true)
  -- the current side still drives as usual
  child.lua([[_G.wheel(_G.right, 'down')]])
  H.eq(H.wait(child, [[_G.top(_G.right) > 1 and _G.top(_G.left) == _G.top(_G.right)]]), true)
end

T['scrollsync']['windows the plugin did not bind are left alone'] = function()
  child.lua([[
    for _, w in ipairs({ _G.left, _G.right }) do
      vim.wo[w].scrollbind = true
    end
  ]])
  child.api.nvim_set_current_win(child.lua_get('_G.right'))
  child.lua([[_G.wheel(_G.left, 'down')]])
  H.eq(H.wait(child, [[_G.top(_G.left) > 1]]), true)
  vim.uv.sleep(100)
  H.eq(child.lua_get('_G.top(_G.right)'), 1) -- Neovim's own behaviour, not ours to change
end

return T
