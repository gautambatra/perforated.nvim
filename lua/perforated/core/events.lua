--- Thin wrapper over `User` autocmds so statuslines and user code can react to plugin state.
--- Event names are emitted as `User Perforated<Name>`, e.g. `User PerforatedStatus`.

local M = {}

---@param name string e.g. 'Status', 'WorkspaceActivated'
---@param data table?
function M.emit(name, data)
  local pattern = 'Perforated' .. name
  if vim.in_fast_event() then
    vim.schedule(function()
      M.emit(name, data)
    end)
    return
  end
  vim.api.nvim_exec_autocmds('User', { pattern = pattern, modeline = false, data = data })
end

return M
