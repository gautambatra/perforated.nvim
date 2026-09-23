--- Activation gate: decides, per buffer and without starting any process, whether a file is
--- inside a Perforce workspace. Loaded on the first BufReadPost; everything else in the plugin is
--- only loaded once this finds a workspace.
---
--- * P4CONFIG name from the environment or the P4ENVIRO file (plain Lua file read).
--- * Upward search for that file, cached for every directory visited.
--- * Not a Perforce user at all (no P4CONFIG, no P4CLIENT) or no `p4` binary: the autocmd is
---   removed and the plugin stays dormant for the session.

local uv = vim.uv

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

local has_p4 ---@type boolean?

--- Stop listening for buffers (plugin/ created the 'perforated' augroup).
local function go_dormant()
  pcall(vim.api.nvim_clear_autocmds, { group = 'perforated' })
end

-- Debug logging of gate decisions, only when debugging was requested (keeps dormancy otherwise).
local want_debug ---@type boolean?
local function gate_log(fmt, ...)
  if want_debug == nil then
    local env = vim.env.PERFORATED_DEBUG
    want_debug = (env ~= nil and env ~= '' and env ~= '0')
      or vim.tbl_get(vim.g, 'perforated', 'debug', 'enabled') == true
  end
  if want_debug then
    require('perforated.core.debug').log('debug', 'gate', fmt, ...)
  end
end

--- BufReadPost/BufNewFile handler (called from plugin/).
---@param ev { buf: integer }
function Gate.on_buf(ev)
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
    gate_log('dormant: neither P4CONFIG nor P4CLIENT is set (env or P4ENVIRO)')
    go_dormant()
    return
  end
  local dir = name:match('^(.*)/[^/]*$')
  dir = (dir == nil or dir == '') and '/' or dir
  local hit = Gate.lookup(dir)
  gate_log(
    '%s: %s',
    name,
    hit and ('P4CONFIG ' .. hit.file)
      or (Gate.env_client() and 'no P4CONFIG above; env P4CLIENT set')
      or ('no ' .. tostring(Gate.config_name()) .. ' above ' .. dir .. ' -> not a workspace')
  )
  if hit or Gate.env_client() then
    if has_p4 == nil then
      has_p4 = vim.fn.executable(vim.tbl_get(vim.g, 'perforated', 'p4') or 'p4') == 1
    end
    if not has_p4 then
      gate_log('dormant: p4 executable not found')
      go_dormant()
      return
    end
    require('perforated.core.activation').attach(buf, name, hit)
  end
end

return Gate
