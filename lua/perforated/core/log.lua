--- Ring buffer of every p4 invocation (argv, cwd, timing, outcome), shown by `:P4 log`.

local M = {}

---@class perforated.LogEntry
---@field time integer   os.time() at start
---@field ms number      wall-clock duration
---@field argv string[]
---@field cwd string?
---@field code integer?
---@field records integer?
---@field err string?    first error line, if any
---@field ws string?     workspace key

local entries = {} ---@type perforated.LogEntry[]
local head = 0 -- index of the newest entry
local count = 0

local function capacity()
  local ok, config = pcall(require, 'perforated.config')
  return ok and config.get().log.size or 500
end

---@param e perforated.LogEntry
function M.add(e)
  local cap = capacity()
  head = head % cap + 1
  entries[head] = e
  count = math.min(count + 1, cap)
end

--- Entries oldest → newest.
---@return perforated.LogEntry[]
function M.entries()
  local cap = capacity()
  local out = {}
  for i = count - 1, 0, -1 do
    local idx = (head - i - 1) % cap + 1
    out[#out + 1] = entries[idx]
  end
  return out
end

function M.clear()
  entries, head, count = {}, 0, 0
end

---@param e perforated.LogEntry
---@return string
function M.format(e)
  local status
  if e.err then
    status = 'ERR'
  elseif e.code == 0 then
    status = 'ok '
  else
    status = ('%3d'):format(e.code or -1)
  end
  local line = ('%s %6.0fms %s %s'):format(
    os.date('%H:%M:%S', e.time),
    e.ms or 0,
    status,
    table.concat(e.argv, ' ')
  )
  if e.records then
    line = line .. ('  [%d rec]'):format(e.records)
  end
  if e.err then
    line = line .. '  ! ' .. e.err
  end
  return line
end

--- Open (or refresh) the log buffer in a split.
function M.open()
  local lines = {}
  for _, e in ipairs(M.entries()) do
    lines[#lines + 1] = M.format(e)
  end
  if #lines == 0 then
    lines = { '(no p4 commands run yet)' }
  end
  local buf = vim.fn.bufnr('perforated://log')
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'perforated://log')
    vim.bo[buf].bufhidden = 'hide'
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'perforated-log'
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd('botright split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(15, math.max(5, #lines)))
    vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true })
    vim.keymap.set('n', 'gr', M.open, { buffer = buf, nowait = true })
  end
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
end

return M
