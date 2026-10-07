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

--- Whether a spec always names the same content. Only numbered revisions do: a shelf (`@=N`)
--- is replaced by every re-shelve, and `#head`, labels and dates move.
---@param spec string
---@return boolean
function M.immutable(spec)
  return spec:match('#%d+$') ~= nil
end

--- Create (or reuse) the buffer for a spec, bound to a workspace. Loading starts immediately.
---
--- Loads the content directly rather than relying on BufReadCmd: autocmds don't fire from
--- inside another autocmd (unless it is `nested`), so a `bufload` from e.g. a CursorMoved
--- handler would otherwise produce an empty buffer.
---
--- Revision buffers outlive the views that show them (`bufhidden=hide`), so a reused buffer of
--- a mutable spec is read again: its old content stays until the new content arrives.
---@param ws perforated.Workspace
---@param spec string
---@return integer buf
function M.buffer(ws, spec)
  local name = M.name(spec)
  local buf = vim.fn.bufadd(name)
  vim.b[buf].perforated_ws = ws.key
  local reuse = vim.api.nvim_buf_is_loaded(buf)
  if not reuse then
    vim.fn.bufload(buf)
  end
  if vim.b[buf].perforated_spec ~= spec then
    M.read(buf) -- BufReadCmd didn't run (nested autocmd) or an earlier load was lost
  elseif reuse and not M.immutable(spec) then
    M.read(buf, { keep = true })
  end
  return buf
end

--- BufReadCmd handler.
---@param buf integer
---@param opts? { keep: boolean }  keep the current content until the new content arrives
function M.read(buf, opts)
  local spec = M.parse(vim.api.nvim_buf_get_name(buf))
  if not spec then
    return
  end
  local keep = opts and opts.keep and vim.b[buf].perforated_loaded
  -- Reads can overlap (a re-read while the first is in flight): only the newest one fills.
  local gen = (vim.b[buf].perforated_read_gen or 0) + 1
  vim.b[buf].perforated_read_gen = gen
  vim.b[buf].perforated_spec = spec
  if keep then
    return M._fetch(buf, spec, gen)
  end
  vim.b[buf].perforated_loaded = false
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
  vim.bo[buf].readonly = false -- a re-read: filling a 'readonly' buffer warns (W10)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ('loading %s …'):format(spec) })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local path = spec:gsub('[#@].*$', '')
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  M._fetch(buf, spec, gen)
end

---@param buf integer
---@param spec string
---@param gen integer
function M._fetch(buf, spec, gen)
  local wsmod = require('perforated.core.workspace')
  local ws = wsmod.get(vim.b[buf].perforated_ws) or wsmod.connection()
  local t0 = vim.uv.hrtime()
  require('perforated.p4').print(ws, spec, {}, function(lines, err)
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].perforated_read_gen ~= gen then
      return
    end
    require('perforated.core.debug').log(
      lines and 'debug' or 'warn',
      'uri',
      '%s: %s in %.0fms',
      spec,
      lines and (#lines .. ' lines') or ('failed: ' .. tostring(err)),
      (vim.uv.hrtime() - t0) / 1e6
    )
    -- 'readonly' off while filling it: changing a readonly buffer warns (W10).
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      lines or { ('[perforated] could not load %s: %s'):format(spec, tostring(err)) }
    )
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modified = false
    vim.b[buf].perforated_loaded = true
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.wo[win].diff then
        vim.api.nvim_win_call(win, function()
          vim.cmd('diffupdate')
        end)
        -- It was empty when the diff opened: line it up with the other side now.
        for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
          if other ~= win and vim.wo[other].diff then
            require('perforated.diff.view').align(other, win, vim.w[other].perforated_first_change)
            vim.w[other].perforated_first_change = nil -- once: from now on the user moves
            break
          end
        end
      end
    end
  end)
end

return M
