--- Always-visible key footer at the bottom of a view window. A one-line, non-focusable float
--- anchored to the window (per-window statuslines are hidden with `laststatus=3`), updated as
--- the cursor moves.

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.footer')

---@class perforated.Footer
---@field win integer        the view window
---@field fwin integer?      the footer float
---@field fbuf integer
local Footer = {}
Footer.__index = Footer

---@param win integer
---@return perforated.Footer
function M.attach(win)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = 'wipe'
  local self = setmetatable({ win = win, fbuf = fbuf }, Footer)
  local group = vim.api.nvim_create_augroup('perforated.footer.' .. win, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      self:place()
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    callback = function()
      self:close()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- Hide while another tab is shown; floats belong to one tab anyway, but re-place on return.
  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      self:place()
    end,
  })
  self.group = group
  return self
end

function Footer:place()
  if not vim.api.nvim_win_is_valid(self.win) then
    return self:close()
  end
  local width = vim.api.nvim_win_get_width(self.win)
  local height = vim.api.nvim_win_get_height(self.win)
  local cfg = {
    relative = 'win',
    win = self.win,
    row = height - 1,
    col = 0,
    width = math.max(width, 1),
    height = 1,
    style = 'minimal',
    focusable = false,
    zindex = 40,
    noautocmd = true,
  }
  if self.fwin and vim.api.nvim_win_is_valid(self.fwin) then
    cfg.noautocmd = nil
    vim.api.nvim_win_set_config(self.fwin, cfg)
  else
    self.fwin = vim.api.nvim_open_win(self.fbuf, false, cfg)
    vim.wo[self.fwin].winhighlight = 'NormalFloat:PerforatedFooter'
  end
end

--- Set footer content (highlight chunks).
---@param chunks { [1]: string, [2]: string? }[]
function Footer:set(chunks)
  if not vim.api.nvim_buf_is_valid(self.fbuf) then
    return
  end
  local text, marks, col = {}, {}, 0
  for _, c in ipairs(chunks) do
    text[#text + 1] = c[1]
    if c[2] then
      marks[#marks + 1] = { col, col + #c[1], c[2] }
    end
    col = col + #c[1]
  end
  vim.api.nvim_buf_set_lines(self.fbuf, 0, -1, false, { table.concat(text) })
  vim.api.nvim_buf_clear_namespace(self.fbuf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(self.fbuf, ns, 0, m[1], { end_col = m[2], hl_group = m[3] })
  end
  self:place()
end

function Footer:close()
  if self.fwin and vim.api.nvim_win_is_valid(self.fwin) then
    pcall(vim.api.nvim_win_close, self.fwin, true)
  end
  self.fwin = nil
end

return M
