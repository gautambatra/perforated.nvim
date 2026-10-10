--- Go-to / lookup (`g/`, `<C-g>`, `:P4 lookup`): a changelist number opens its describe
--- buffer, a path its history (a directory: its changelists), anything else a user's
--- submitted changelists.

local M = {}

--- The lookup prompt's workspace: a function (resolved when the key is pressed) or a value;
--- default: the current buffer's, else the connection.
local function resolve(ws)
  if type(ws) == 'function' then
    ws = ws()
  end
  local wsmod = require('perforated.core.workspace')
  return ws or wsmod.for_buf(0) or wsmod.current() or wsmod.connection()
end

--- The lookup as a registry action (`g/`, P4V `<C-g>`), the same in every Perforce window:
--- user overrides by id (`keys = { lookup = … }`) and `keys.p4v = false` apply everywhere.
---@param ws perforated.Workspace|fun(): perforated.Workspace|nil
---@return perforated.Action
function M.action(ws)
  return {
    id = 'lookup',
    desc = 'Go to changelist / path / user',
    keys = { 'g/' },
    p4v = { '<C-g>' },
    nomenu = true,
    run = function()
      M.run(resolve(ws))
    end,
  }
end

--- Map the lookup keys in a window outside the action registry (diff views, the changelist
--- pop-up, revision buffers, quickfix lists).
---@param buf integer
---@param ws perforated.Workspace|fun(): perforated.Workspace|nil
---@param map fun(lhs: string, fn: fun(), desc: string)?  default: a buffer-local mapping
function M.map(buf, ws, map)
  local a = M.action(ws)
  map = map
    or function(lhs, fn, desc)
      vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
  for _, lhs in ipairs(require('perforated.ui.keys').keys_of(a)) do
    map(lhs, a.run, 'perforated: ' .. a.desc)
  end
end

---@param ws perforated.Workspace
---@param what string?  nil = prompt
function M.run(ws, what)
  if not what or what == '' then
    return require('perforated.ui.prompt').input(
      { prompt = 'Go to (CL number, path or user): ' },
      function(input)
        if input and vim.trim(input) ~= '' then
          M.run(ws, vim.trim(input))
        end
      end
    )
  end
  local cl = what:match('^@?(%d+)$')
  if cl then
    return require('perforated.views.describe').open(ws, cl)
  end
  -- A bare word is a user unless it names a file here (`foo.c`); anything with a slash is a path.
  local stat = vim.uv.fs_stat(vim.fn.expand(what, false, true)[1] or what)
  if what:match('^//') or what:find('/', 1, true) or (stat and stat.type == 'file') then
    local path = what
    if not path:match('^//') then
      path = vim.fn.fnamemodify(vim.fn.expand(path, false, true)[1] or path, ':p')
    end
    return require('perforated.views.history').open(ws, path)
  end
  require('perforated.views.changes').open(
    ws,
    { user = what, path = ws.mode == 'connection' and '//...' or nil }
  )
end

return M
