-- perforated.nvim — Perforce integration for Neovim.
--
-- This file is deliberately tiny: it defines the :P4 commands and one autocmd. Nothing else is
-- loaded until a buffer inside a Perforce workspace is opened (or a :P4 command is run).
-- Outside Perforce the plugin costs one cached directory lookup per new directory.

if vim.g.loaded_perforated then
  return
end
vim.g.loaded_perforated = true

if vim.fn.has('nvim-0.11') == 0 then
  return
end

local uv = vim.uv

-- ---------------------------------------------------------------------------------------------
-- Activation gate (exposed as package.loaded['perforated.gate'])
-- ---------------------------------------------------------------------------------------------

local Gate = {}
local dirs = {} ---@type table<string, table|false>  dir → { anchor, file } | false
local cfg_name ---@type string|false|nil             nil = not computed yet
local env_client ---@type boolean?

local function enviro_get(key)
  local path = uv.os_getenv('P4ENVIRO')
  if not path or path == '' then
    path = (uv.os_homedir() or '') .. '/.p4enviro'
  end
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local val
  for line in fd:lines() do
    local k, v = line:match('^%s*([%w_]+)=(.-)%s*$')
    if k == key and v ~= '' then
      val = v
    end
  end
  fd:close()
  return val
end

local function setting(key)
  local v = uv.os_getenv(key)
  if v and v ~= '' then
    return v
  end
  return enviro_get(key)
end

--- P4CONFIG file name, or false when not configured.
function Gate.config_name()
  if cfg_name == nil then
    local name = setting('P4CONFIG')
    cfg_name = (name and not name:find('/', 1, true)) and name or false
  end
  return cfg_name
end

--- Is P4CLIENT set without a P4CONFIG file (environment-only setup)?
function Gate.env_client()
  if env_client == nil then
    env_client = setting('P4CLIENT') ~= nil
  end
  return env_client
end

local function parent(d)
  if d == '/' then
    return nil
  end
  local p = d:match('^(.+)/[^/]+$')
  return p or '/'
end

--- Find the P4CONFIG anchor for a directory. Pure Lua (fs_stat per new ancestor), cached for
--- every directory visited on the way up.
---@param dir string absolute, normalised
---@return { anchor: string, file: string }|false
function Gate.lookup(dir)
  local hit = dirs[dir]
  if hit ~= nil then
    return hit
  end
  local name = Gate.config_name()
  if not name then
    return false
  end
  local visited = {}
  local d = dir
  while d do
    local c = dirs[d]
    if c ~= nil then
      hit = c
      break
    end
    visited[#visited + 1] = d
    local file = (d == '/' and '' or d) .. '/' .. name
    local st = uv.fs_stat(file)
    if st and st.type == 'file' then
      hit = { anchor = d, file = file }
      break
    end
    d = parent(d)
  end
  hit = hit or false
  for _, v in ipairs(visited) do
    dirs[v] = hit
  end
  return hit
end

function Gate.reset()
  dirs, cfg_name, env_client = {}, nil, nil
end

package.loaded['perforated.gate'] = Gate

local group = vim.api.nvim_create_augroup('perforated', { clear = true })
local has_p4 ---@type boolean?

local function on_buf(ev)
  local buf = ev.buf
  if vim.bo[buf].buftype ~= '' then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:find('^%a[%w+.-]*://') then
    return
  end
  if not Gate.config_name() and not Gate.env_client() then
    -- Not a Perforce user (in this environment): go fully dormant.
    vim.api.nvim_clear_autocmds({ group = group })
    return
  end
  local dir = name:match('^(.*)/[^/]*$')
  dir = (dir == nil or dir == '') and '/' or dir
  local hit = Gate.lookup(dir)
  if hit or Gate.env_client() then
    if has_p4 == nil then
      has_p4 = vim.fn.executable(vim.tbl_get(vim.g, 'perforated', 'p4') or 'p4') == 1
    end
    if not has_p4 then
      vim.api.nvim_clear_autocmds({ group = group })
      return
    end
    require('perforated.core.activation').attach(buf, name, hit)
  end
end

vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
  group = group,
  desc = 'perforated: activate for buffers inside Perforce workspaces',
  callback = on_buf,
})

-- Lazy-loaded after startup (plugin managers): pick up buffers that are already open.
if vim.v.vim_did_enter == 1 then
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      on_buf({ buf = buf })
    end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Commands: `:P4 <sub> …` plus flat aliases (`:P4info`, …). Keep `subs` in sync with
-- lua/perforated/commands.lua (a test enforces it).
-- ---------------------------------------------------------------------------------------------

local subs = {
  'add',
  'diff',
  'dismiss',
  'edit',
  'hunks',
  'info',
  'log',
  'login',
  'notifications',
  'opened',
  'refresh',
  'revert',
  'status',
}

vim.api.nvim_create_user_command('P4', function(o)
  require('perforated.commands').run(o)
end, {
  nargs = '*',
  bang = true,
  range = true,
  desc = 'Perforce: :P4 <subcommand> [args]',
  complete = function(arglead, cmdline, pos)
    return require('perforated.commands').complete(arglead, cmdline, pos)
  end,
})

if vim.tbl_get(vim.g, 'perforated', 'commands', 'aliases') ~= false then
  for _, sub in ipairs(subs) do
    vim.api.nvim_create_user_command('P4' .. sub, function(o)
      require('perforated.commands').dispatch(sub, o)
    end, {
      nargs = '*',
      bang = true,
      range = true,
      desc = 'Perforce: :P4 ' .. sub,
      complete = function(arglead, cmdline, pos)
        return require('perforated.commands').complete_args(sub, arglead, cmdline, pos)
      end,
    })
  end
end

-- Depot revisions as buffers: `:e perforated:////depot/path/file.c#3`.
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('perforated.uri', { clear = true }),
  pattern = 'perforated:////*',
  callback = function(ev)
    require('perforated.uri').read(ev.buf)
  end,
})

-- <Plug>(perforated-…) mappings; nothing is loaded until one is used.
for _, name in ipairs({
  'next-hunk',
  'prev-hunk',
  'preview-hunk',
  'reset-hunk',
  'edit',
  'edit-prompt',
  'add',
  'revert',
  'diff',
  'diff-external',
  'hunks',
  'hunks-file',
  'opened',
  'status',
  'info',
  'log',
  'notifications',
}) do
  vim.api.nvim_set_keymap(
    'n',
    '<Plug>(perforated-' .. name .. ')',
    "<Cmd>lua require('perforated.keymaps').run('" .. name .. "')<CR>",
    { noremap = true, desc = 'perforated: ' .. name }
  )
end
