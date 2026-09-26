--- Progress for long p4 operations (sync, submit). Neovim 0.12+ progress messages (shown by
--- the message area and forwarded to fidget/snacks by those plugins); `vim.notify` otherwise.

local M = {}

local has_progress = vim.fn.has('nvim-0.12') == 1

---@class perforated.Progress
---@field id integer|string|nil
---@field title string

--- Start a progress item.
---@param title string   e.g. 'p4 sync'
---@param msg string
---@return perforated.Progress
function M.start(title, msg)
  local p = { title = title }
  if has_progress then
    local ok, id = pcall(
      vim.api.nvim_echo,
      { { msg } },
      false,
      { kind = 'progress', title = title, status = 'running' }
    )
    if ok then
      p.id = id
      return p
    end
  end
  vim.notify(('[perforated] %s: %s'):format(title, msg))
  return p
end

--- Update a running progress item (no-op without progress messages: no notification spam).
---@param p perforated.Progress
---@param msg string
function M.update(p, msg)
  if has_progress and p.id then
    pcall(
      vim.api.nvim_echo,
      { { msg } },
      false,
      { kind = 'progress', id = p.id, title = p.title, status = 'running' }
    )
  end
end

--- Finish a progress item.
---@param p perforated.Progress
---@param msg string
---@param failed boolean?
function M.finish(p, msg, failed)
  if has_progress and p.id then
    local ok = pcall(vim.api.nvim_echo, { { msg } }, true, {
      kind = 'progress',
      id = p.id,
      title = p.title,
      status = failed and 'failed' or 'success',
      percent = 100,
    })
    if ok then
      return
    end
  end
  vim.notify(
    ('[perforated] %s: %s'):format(p.title, msg),
    failed and vim.log.levels.ERROR or vim.log.levels.INFO
  )
end

return M
