--- perforated.nvim public API.
---
--- `setup()` is optional: configuration can also be given via `vim.g.perforated`.

local M = {}

--- Merge options over the defaults (and `vim.g.perforated`). Never required.
---@param opts table?
function M.setup(opts)
  require('perforated.config').set(opts)
end

--- Workspace of a buffer (default: current), or nil.
---@param buf integer?
---@return perforated.Workspace?
function M.workspace(buf)
  local ws = package.loaded['perforated.core.workspace']
  return ws and ws.for_buf(buf) or nil
end

--- Statusline component for the current buffer (file state + workspace markers). Reads only
--- cached variables; safe to call on every redraw. Returns '' outside Perforce.
---@return string
function M.statusline()
  local status = package.loaded['perforated.status']
  return status and status.statusline() or ''
end

return M
