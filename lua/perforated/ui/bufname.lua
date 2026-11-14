--- Names for the plugin's scratch buffers, so `:ls`, a statusline or a buffer picker shows
--- what each one is: `perforated://<what>`, e.g. `perforated://description/1234`.

local M = {}

--- Name `buf` `perforated://<name>`; ` (2)`, ` (3)`, … when another buffer has that name
--- (Neovim refuses a name in use, which would leave the buffer unnamed).
---@param buf integer
---@param name string
function M.set(buf, name)
  local full = 'perforated://' .. name
  for n = 1, 50 do
    if pcall(vim.api.nvim_buf_set_name, buf, n == 1 and full or ('%s (%d)'):format(full, n)) then
      return
    end
  end
end

return M
