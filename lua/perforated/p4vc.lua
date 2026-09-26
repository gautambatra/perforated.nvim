--- P4V escape hatches through `p4vc` (when installed): the revision graph, P4V's time-lapse
--- and the stream graph. Launched detached, with the user's environment, from the
--- workspace's directory (so P4CONFIG applies).

local M = {}

---@return string?  the p4vc executable, if found
function M.bin()
  local b = require('perforated.config').get().p4vc or 'p4vc'
  return vim.fn.executable(b) == 1 and b or nil
end

function M.available()
  return M.bin() ~= nil
end

--- `p4vc <cmd> [path]`.
---@param ws perforated.Workspace
---@param cmd 'revgraph'|'timelapse'|'streamgraph'
---@param path string?
function M.run(ws, cmd, path)
  local bin = M.bin()
  if not bin then
    return vim.notify(
      '[perforated] p4vc not found (set p4vc = "/path/to/p4vc")',
      vim.log.levels.WARN
    )
  end
  local argv = { bin, cmd }
  if path then
    argv[#argv + 1] = path
  end
  local cwd = ws:cwd()
  local ok, err = pcall(
    vim.system,
    argv,
    { cwd = cwd, env = { PWD = cwd }, detach = true },
    function(res)
      if res.code ~= 0 then
        vim.schedule(function()
          vim.notify(
            ('[perforated] p4vc %s failed: %s'):format(cmd, vim.trim(res.stderr or '')),
            vim.log.levels.ERROR
          )
        end)
      end
    end
  )
  if not ok then
    return vim.notify('[perforated] p4vc: ' .. tostring(err), vim.log.levels.ERROR)
  end
  vim.notify(('[perforated] p4vc %s%s'):format(cmd, path and (' ' .. path) or ''))
end

--- Registry actions for a view: revgraph (`gR` / `<C-S-r>`) and P4V's time-lapse, on items
--- whose file `path_of(item)` returns. Only when p4vc is installed.
---@param ws perforated.Workspace
---@param kinds table<string, boolean>?
---@param path_of fun(item: any): string?
---@return perforated.Action[]
function M.actions(ws, kinds, path_of)
  local function when(item)
    return M.available() and path_of(item) ~= nil
  end
  return {
    {
      id = 'revgraph',
      desc = 'Revision graph (p4vc)',
      keys = { 'gR' },
      p4v = { '<C-S-r>' },
      kinds = kinds,
      when = when,
      run = function(items)
        M.run(ws, 'revgraph', path_of(items[1]))
      end,
    },
    {
      id = 'p4vc_timelapse',
      desc = 'Time-lapse in P4V (p4vc)',
      kinds = kinds,
      when = when,
      run = function(items)
        M.run(ws, 'timelapse', path_of(items[1]))
      end,
    },
  }
end

return M
