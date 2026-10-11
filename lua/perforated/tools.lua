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

--- Why a GUI tool can't open a window here, or nil. On X11/Wayland systems (not macOS or
--- Windows) it needs $DISPLAY or $WAYLAND_DISPLAY, which a tmux server started outside the
--- desktop session (or over ssh) doesn't have: the tool would quit at once.
---@return string?
function M.no_display()
  if vim.fn.has('mac') == 1 or vim.fn.has('win32') == 1 then
    return nil
  end
  if (vim.env.DISPLAY or '') == '' and (vim.env.WAYLAND_DISPLAY or '') == '' then
    return 'no display: $DISPLAY and $WAYLAND_DISPLAY are unset in Neovim'
  end
end

--- The last lines a failed tool printed, joined (a reason for a pop-up).
---@param text string?
---@return string?
local function last_words(text)
  local lines = {}
  for l in vim.gsplit(text or '', '\n', { plain = true }) do
    l = vim.trim(l)
    if l ~= '' then
      lines[#lines + 1] = l
    end
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(vim.list_slice(lines, math.max(1, #lines - 1)), ' ')
end

--- Run `tool file…` (through `sh`, so the setting may carry arguments). `on_exit` gets the
--- exit code and, when it failed, what the tool printed last (its stderr; for a terminal
--- tool, the end of its screen) — e.g. "cannot open display".
---@param ws perforated.Workspace
---@param tool string
---@param files string[]
---@param on_exit fun(code: integer, err: string?)
function M.run(ws, tool, files, on_exit)
  local cwd = ws:cwd()
  local argv = vim.list_extend({ 'sh', '-c', tool .. ' "$@"', 'p4tool' }, files)
  if M.is_terminal(tool) then
    vim.cmd('tabnew')
    local tab = vim.api.nvim_get_current_tabpage()
    local term_buf = vim.api.nvim_get_current_buf()
    vim.fn.jobstart(argv, {
      term = true,
      cwd = cwd,
      env = { PWD = cwd },
      on_exit = function(_, code)
        vim.schedule(function()
          local err
          if code ~= 0 and vim.api.nvim_buf_is_valid(term_buf) then
            err = last_words(
              table
                .concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), '\n')
                :gsub('%[Process exited %d+%]', '')
            )
          end
          if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
            pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
          end
          on_exit(code, err)
        end)
      end,
    })
    vim.cmd('startinsert')
  else
    local why = M.no_display()
    if why then
      return vim.schedule(function()
        on_exit(-1, why)
      end)
    end
    vim.system(argv, { cwd = cwd, env = { PWD = cwd }, text = true }, function(res)
      vim.schedule(function()
        on_exit(res.code, res.code ~= 0 and last_words(res.stderr) or nil)
      end)
    end)
  end
end

return M
