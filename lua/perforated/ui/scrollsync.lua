--- Scroll-bound plugin windows (diff sides, annotate) stay together when the window that
--- scrolls isn't the current one. The mouse wheel scrolls the window under the pointer, and
--- Neovim only syncs 'scrollbind' windows when the current window scrolls (at the end of a
--- Normal-mode command, diff-aware: filler lines and all). So when a marked, bound window that
--- isn't current scrolls, it briefly becomes current (no autocmds) and scrolls one line up and
--- back (`CTRL-Y` `CTRL-E`; the other way at the top): Neovim lines every bound window up with
--- it. Back in the original window a no-op `<Esc>` makes it the one Neovim compares the next
--- scroll against (else the user's next scroll there wouldn't sync).
---
--- Tried and dropped: `:syncbind` (not diff-aware: same line numbers; it also makes Neovim skip
--- the next sync, i.e. the user's next scroll) and scrolling the current window by the same
--- count (wrong through filler lines). Our own sync shows up in the next WinScrolled event,
--- maybe together with the user's next scroll: `own` remembers where it left every bound
--- window, so only a window that moved since counts as scrolled by the user.
---
--- Only windows the plugin marked with `watch`: other scroll-bound windows keep Neovim's own
--- behaviour.

local M = {}

local did_autocmd = false

---@type table<integer, string>?  where our own sync left each bound window (`pos`)
local own

local function bound(w)
  return vim.api.nvim_win_is_valid(w) and vim.w[w].perforated_scrollsync and vim.wo[w].scrollbind
end

--- Top line and filler lines above it (scrolling through filler lines keeps the top line).
local function pos(w)
  local v = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  return v.topline .. ':' .. v.topfill
end

--- Did the user scroll `w` (rather than our last sync)?
local function moved(w)
  return not (own and own[w] == pos(w))
end

--- Line every bound window up with `w`, through Neovim's own (diff-aware) scroll binding.
---@param w integer
---@param cur integer  the current window, current again afterwards
local function sync_from(w, cur)
  local ok = pcall(function()
    vim.cmd('noautocmd call win_gotoid(' .. w .. ')')
    -- The first command in a window only records where it is; the second scroll syncs.
    local v = vim.fn.winsaveview() -- (not line('w0'): it could scroll to the cursor)
    local at_top = v.topline == 1 and v.topfill == 0
    vim.cmd('normal! ' .. (at_top and '\5\25' or '\25\5'))
  end)
  vim.cmd('noautocmd call win_gotoid(' .. cur .. ')')
  pcall(vim.cmd, 'normal! \27')
  return ok
end

local function on_scrolled()
  local cur = vim.api.nvim_get_current_win()
  local ev = vim.v.event
  if ev[tostring(cur)] and bound(cur) and moved(cur) then
    own = nil
    return -- the user scrolled the current window: Neovim synced the others
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for key in pairs(ev) do
    local w = tonumber(key)
    if w and w ~= cur and bound(w) and vim.api.nvim_win_get_tabpage(w) == tab and moved(w) then
      sync_from(w, cur)
      own = {}
      for _, x in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if bound(x) then
          own[x] = pos(x)
        end
      end
      return
    end
  end
end

--- Keep scroll-bound windows together when this one scrolls without being current.
---@param win integer
function M.watch(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.w[win].perforated_scrollsync = true
  if not did_autocmd then
    did_autocmd = true
    vim.api.nvim_create_autocmd('WinScrolled', {
      group = vim.api.nvim_create_augroup('perforated.scrollsync', { clear = true }),
      callback = on_scrolled,
    })
  end
end

return M
