--- The user's external tools ($P4MERGE, …): read their setting the way p4 does and launch
--- them with the user's untouched environment — a terminal tab for terminal tools, detached
--- for GUI ones — calling back with the exit code.

local M = {}

--- A p4 setting (environment, P4CONFIG, P4ENVIRO), e.g. 'P4MERGE'.
---@param ws perforated.Workspace
---@param name string
---@param cb fun(value: string?)
function M.setting(ws, name, cb)
  local bin = require('perforated.core.env').p4_bin() or 'p4'
  local cwd = ws:cwd()
  vim.system(
    { bin, 'set', '-q', name },
    { cwd = cwd, env = { PWD = cwd }, text = true },
    function(r)
      local v = vim.trim((r.stdout or ''):match(name .. '=([^\n]*)') or '')
      vim.schedule(function()
        cb(v ~= '' and v or nil)
      end)
    end
  )
end

--- The merge tool command: `merge.tool`, else $P4MERGE.
---@param ws perforated.Workspace
---@param cb fun(tool: string?)
function M.merge_tool(ws, cb)
  local cfg = require('perforated.config').get().merge.tool
  if cfg and cfg ~= '' then
    return vim.schedule(function()
      cb(cfg)
    end)
  end
  M.setting(ws, 'P4MERGE', cb)
end

--- Is this a terminal tool (runs in a terminal tab) rather than a GUI one?
---@param tool string
---@return boolean
function M.is_terminal(tool)
  local mode = require('perforated.config').get().diff.external_terminal
  if mode == true or mode == false then
    return mode
  end
  local exe = vim.fs.basename(vim.split(vim.trim(tool), '%s+')[1]):lower():gsub('%.exe$', '')
  return not require('perforated.diff.view').GUI[exe]
end

--- Run `tool file…` (through `sh`, so the setting may carry arguments).
---@param ws perforated.Workspace
---@param tool string
---@param files string[]
---@param on_exit fun(code: integer)
function M.run(ws, tool, files, on_exit)
  local cwd = ws:cwd()
  local argv = vim.list_extend({ 'sh', '-c', tool .. ' "$@"', 'p4tool' }, files)
  if M.is_terminal(tool) then
    vim.cmd('tabnew')
    local tab = vim.api.nvim_get_current_tabpage()
    vim.fn.jobstart(argv, {
      term = true,
      cwd = cwd,
      env = { PWD = cwd },
      on_exit = function(_, code)
        vim.schedule(function()
          if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
            pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
          end
          on_exit(code)
        end)
      end,
    })
    vim.cmd('startinsert')
  else
    vim.system(argv, { cwd = cwd, env = { PWD = cwd } }, function(res)
      vim.schedule(function()
        on_exit(res.code)
      end)
    end)
  end
end

return M
