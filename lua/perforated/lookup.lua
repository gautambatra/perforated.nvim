--- Go-to / lookup (`g/`, `<C-g>`, `:P4 lookup`): a changelist number opens its describe
--- buffer, a path its history (a directory: its changelists), anything else a user's
--- submitted changelists.

local M = {}

---@param ws perforated.Workspace
---@param what string?  nil = prompt
function M.run(ws, what)
  if not what or what == '' then
    return vim.ui.input({ prompt = 'Go to (CL number, path or user): ' }, function(input)
      if input and vim.trim(input) ~= '' then
        M.run(ws, vim.trim(input))
      end
    end)
  end
  local cl = what:match('^@?(%d+)$')
  if cl then
    return require('perforated.views.describe').open(ws, cl)
  end
  -- A bare word is a user unless it names a file here (`foo.c`); anything with a slash is a path.
  local stat = vim.uv.fs_stat(vim.fn.expand(what))
  if what:match('^//') or what:find('/', 1, true) or (stat and stat.type == 'file') then
    local path = what
    if not path:match('^//') then
      path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
    end
    return require('perforated.views.history').open(ws, path)
  end
  require('perforated.views.changes').open(
    ws,
    { user = what, path = ws.mode == 'connection' and '//...' or nil }
  )
end

return M
