--- `:P4 messages`: the toast history window (loaded on first use, not with every workspace).

local M = {}

--- Open the toast history (newest first) in a scratch buffer.
---@param history table[]
function M.open(history)
  local lines = {}
  for i = #history, 1, -1 do
    local t = history[i]
    lines[#lines + 1] = os.date('%H:%M:%S ', t.time) .. t.title
    for _, l in ipairs(t.lines) do
      lines[#lines + 1] = '    ' .. l
    end
  end
  if #lines == 0 then
    lines = { '(no messages)' }
  end
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'perforated-messages'
  vim.api.nvim_win_set_height(0, math.min(15, #lines))
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true })
end

return M
