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

-- Words that mark the line saying what went wrong.
local ERROR_WORDS = {
  'could not',
  'cannot',
  "can't",
  "couldn't", -- Tk: "couldn't connect to display"
  'unable',
  'error',
  'failed',
  'fatal',
  'not found',
  'no such',
  'denied',
}

--- The line of a failed tool's output that says what went wrong (a reason for a pop-up): the
--- first one with an error word, else the last. Qt's display failure, for one, prints
--- "could not connect to display" first and ends with a list of plugins and the shell's
--- "Aborted (core dumped)". `strict`: only a line with an error word (nil otherwise).
---@param text string?
---@param strict boolean?
---@return string?
function M.error_line(text, strict)
  local lines = {}
  for l in vim.gsplit(text or '', '\n', { plain = true }) do
    l = vim.trim(l)
    -- the shell reporting the crash, not the tool
    if l ~= '' and not l:match('%(core dumped%)$') and not l:match('^Aborted$') then
      lines[#lines + 1] = l
    end
  end
  if #lines == 0 then
    return nil
  end
  local pick
  for _, l in ipairs(lines) do
    local low = l:lower()
    for _, w in ipairs(ERROR_WORDS) do
      if low:find(w, 1, true) then
        pick = l
        break
      end
    end
    if pick then
      break
    end
  end
  if not pick then
    if strict then
      return nil
    end
    pick = lines[#lines]
  end
  if vim.fn.strchars(pick) > 100 then
    pick = vim.fn.strcharpart(pick, 0, 99) .. '…'
  end
  return pick
end

--- A `vim.system` result's exit code, counting death by a signal as the shell does (128 +
--- signal). A tool that crashes (Qt aborting without a display: SIGABRT) reports code 0 and
--- signal 6 when `sh -c` hands over to it (bash does for a single command), which looked
--- like a clean exit; the shell running it by hand says 134.
---@param res vim.SystemCompleted
---@return integer
function M.exit_code(res)
  if res.signal and res.signal ~= 0 then
    return 128 + res.signal
  end
  return res.code
end

--- Run `tool file…` (through `sh`, so the setting may carry arguments). `on_exit` gets the
--- exit code and, when it failed, the line of its output that says why (`error_line`; its
--- stderr, or for a terminal tool its screen) — e.g. "could not connect to display". A GUI
--- tool's whole stderr goes to the debug log.
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
            err = M.error_line(
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
      local code = M.exit_code(res)
      vim.schedule(function()
        if code ~= 0 then
          require('perforated.core.debug').log(
            'warn',
            'tools',
            '%s exited with %d: %s',
            tool,
            code,
            res.stderr or ''
          )
        end
        on_exit(code, code ~= 0 and M.error_line(res.stderr) or nil)
      end)
    end)
  end
end

return M
