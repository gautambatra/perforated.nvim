--- Perforce environment resolution that needs no server round-trip, and the child-process
--- environment used for p4 calls.

local M = {}

local uv = vim.uv

--- Variables that make p4 launch external programs. Internal (background) calls neutralise
--- them so a stray launch fails fast instead of hanging a headless child process. Calls the
--- user explicitly asks for (external diff/merge) keep the user's environment untouched.
M.NEUTRALISE = { P4EDITOR = 'false', P4DIFF = 'false', P4MERGE = 'false' }
M.REMOVE = { 'P4PAGER' }

---@return string
function M.enviro_path()
  local p = uv.os_getenv('P4ENVIRO')
  if p and p ~= '' then
    return p
  end
  return (uv.os_homedir() or '~') .. '/.p4enviro'
end

local enviro_cache ---@type table<string,string>?

--- Parse the P4ENVIRO file (`p4 set` storage). Pure Lua, cached for the session.
---@return table<string,string>
function M.enviro()
  if enviro_cache then
    return enviro_cache
  end
  local out = {}
  local fd = io.open(M.enviro_path(), 'r')
  if fd then
    for line in fd:lines() do
      local k, v = line:match('^%s*([%w_]+)=(.-)%s*$')
      if k then
        out[k] = v
      end
    end
    fd:close()
  end
  enviro_cache = out
  return out
end

--- Value of a p4 setting from the environment, falling back to P4ENVIRO. Does not consult
--- P4CONFIG files (those are directory-dependent; see activation).
---@param name string
---@return string?
function M.get(name)
  local v = uv.os_getenv(name)
  if v and v ~= '' then
    return v
  end
  v = M.enviro()[name]
  if v and v ~= '' then
    return v
  end
  return nil
end

--- The P4CONFIG file name, if configured. A value containing a path separator is treated as
--- "no per-directory config" (p4 only searches for bare names).
---@return string?
function M.config_name()
  local name = M.get('P4CONFIG')
  if name and not name:find('/', 1, true) then
    return name
  end
  return nil
end

--- True when a workspace is configured without a P4CONFIG file (P4CLIENT set explicitly in
--- the environment or P4ENVIRO). P4PORT alone is not enough: that's common on machines where
--- workspaces are selected per directory, and would cost a `p4 info` for nothing.
---@return boolean
function M.has_env_client()
  return M.get('P4CLIENT') ~= nil
end

--- Build the environment for a p4 child process.
---@param cwd string
---@param mode 'internal'|'user'
---@return table<string,string>
function M.child_env(cwd, mode)
  local env = uv.os_environ()
  env.PWD = cwd
  if mode ~= 'user' then
    for k, v in pairs(M.NEUTRALISE) do
      env[k] = v
    end
    for _, k in ipairs(M.REMOVE) do
      env[k] = nil
    end
  end
  return env
end

local bin_cache = {} ---@type table<string, string|false>

--- Resolve the p4 executable to an absolute path; nil when unavailable. Cached per name.
---@return string?
function M.p4_bin()
  local ok, config = pcall(require, 'perforated.config')
  local bin = ok and config.get().p4 or 'p4'
  local hit = bin_cache[bin]
  if hit == nil then
    local path = vim.fn.exepath(bin)
    hit = path ~= '' and path or false
    bin_cache[bin] = hit
  end
  return hit or nil
end

function M.reset()
  enviro_cache = nil
  bin_cache = {}
end

return M
