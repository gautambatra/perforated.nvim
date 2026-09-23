--- `perforated://` buffers: any depot revision as a read-only buffer.
---
---   perforated:////depot/path/file.c#3     revision 3
---   perforated:////depot/path/file.c#head  head revision
---   perforated:////depot/path/file.c@1234  as of changelist 1234
---   perforated:////depot/path/file.c@=1234 shelved in changelist 1234
---
--- Content loads asynchronously (never blocks); diff mode is refreshed when it arrives.

local M = {}

M.PREFIX = 'perforated://'

---@param spec string
---@return string
function M.name(spec)
  return M.PREFIX .. spec
end

---@param name string
---@return string? spec
function M.parse(name)
  local spec = name:match('^perforated://(//.+)$')
  return spec
end

--- Create (or reuse) the buffer for a spec, bound to a workspace. Loading starts immediately.
---@param ws perforated.Workspace
---@param spec string
---@return integer buf
function M.buffer(ws, spec)
  local name = M.name(spec)
  local buf = vim.fn.bufadd(name)
  vim.b[buf].perforated_ws = ws.key
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  return buf
end

--- BufReadCmd handler.
---@param buf integer
function M.read(buf)
  local spec = M.parse(vim.api.nvim_buf_get_name(buf))
  if not spec then
    return
  end
  local wsmod = require('perforated.core.workspace')
  -- Workspace: set by whoever created the buffer, else the buffer the user came from, else
  -- cwd's workspace, else a plain connection.
  local key = vim.b[buf].perforated_ws
  local alt = vim.fn.bufnr('#')
  local ws = (key and wsmod.get(key))
    or (alt > 0 and wsmod.for_buf(alt))
    or wsmod.current()
    or wsmod.connection()
  vim.b[buf].perforated_ws = ws.key

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local path = spec:gsub('[#@].*$', '')
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end

  require('perforated.p4').print(ws, spec, {}, function(lines, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { '[perforated] ' .. tostring(err) })
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    vim.b[buf].perforated_loaded = true
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.wo[win].diff then
        vim.api.nvim_win_call(win, function()
          vim.cmd('diffupdate')
        end)
      end
    end
  end)
end

return M
