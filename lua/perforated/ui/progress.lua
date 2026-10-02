--- Progress for long p4 operations (sync, submit, reconcile).
---
--- Pop-ups (the default `toast.backend`): one when the job starts and one with its result; the
--- running state is in `:P4 jobs`, never in the message area.
--- `toast.backend = 'notify'`: Neovim 0.12+ progress messages while running (the message area;
--- fidget/snacks pick them up), and the result through vim.notify.

local M = {}

--- Native progress messages: only with the vim.notify backend (pop-ups never use the message
--- area) and on Neovim 0.12+.
local function native()
  return vim.fn.has('nvim-0.12') == 1
    and require('perforated.config').get().toast.backend == 'notify'
end

---@class perforated.Progress
---@field id integer|string|nil
---@field title string

--- Start a progress item.
---@param title string   e.g. 'p4 sync'
---@param msg string
---@return perforated.Progress
function M.start(title, msg)
  local p = { title = title }
  if native() then
    local ok, id = pcall(
      vim.api.nvim_echo,
      { { msg } },
      false,
      { kind = 'progress', title = title, status = 'running', source = 'perforated' }
    )
    if ok then
      p.id = id
      return p
    end
  end
  require('perforated.ui.toast').notify(('[perforated] %s: %s'):format(title, msg))
  return p
end

--- Update a running progress item (no-op without progress messages: no notification spam).
---@param p perforated.Progress
---@param msg string
function M.update(p, msg)
  if p.id then
    pcall(
      vim.api.nvim_echo,
      { { msg } },
      false,
      { kind = 'progress', id = p.id, title = p.title, status = 'running', source = 'perforated' }
    )
  end
end

--- Finish a progress item.
---@param p perforated.Progress
---@param msg string
---@param failed boolean?
function M.finish(p, msg, failed)
  if p.id then
    pcall(vim.api.nvim_echo, { { msg } }, false, {
      kind = 'progress',
      id = p.id,
      title = p.title,
      status = failed and 'failed' or 'success',
      percent = 100,
      source = 'perforated',
    })
  end
  -- A failure needs attention like an action's result; success is background news (the job
  -- may finish long after it was started).
  require('perforated.ui.toast').notify(
    ('[perforated] %s: %s'):format(p.title, msg),
    failed and vim.log.levels.ERROR or vim.log.levels.INFO,
    { place = failed and 'action' or 'background' }
  )
end

return M
