--- Activation: turns a buffer/directory into a Workspace, or leaves it dormant.
---
--- The cheap part (per-directory P4CONFIG lookup, no processes) lives in plugin/perforated.lua
--- as `package.loaded['perforated.gate']`, so nothing is loaded outside Perforce workspaces.
--- This module is only required once the gate found a P4CONFIG anchor, or when an
--- environment-only setup (P4CLIENT/P4PORT set, no P4CONFIG file) needs one `p4 info` to
--- learn the client root.

local workspace = require('perforated.core.workspace')

local M = {}

---@alias perforated.GateHit { anchor: string, file: string }

---@return table gate
local function gate()
  if not package.loaded['perforated.gate'] then
    -- plugin/ not sourced (e.g. --noplugin): it defines the gate.
    vim.cmd.runtime('plugin/perforated.lua')
  end
  return package.loaded['perforated.gate']
end

-- Environment-only state (one `p4 info` per session).
local env = {
  state = 'unknown', ---@type 'unknown'|'pending'|'ready'|'none'
  root = nil, ---@type string?
  icase = false,
  info = nil, ---@type table?
  pending = {}, ---@type { buf: integer, path: string }[]
}

---@param found perforated.GateHit
---@return perforated.Workspace
local function config_ws(found)
  local ws = workspace.get(found.anchor) -- fast path: anchors from the gate are normalised
  if ws then
    return ws
  end
  local anchor = workspace.normalize(found.anchor)
  return workspace.get_or_create({
    key = anchor,
    anchor = anchor,
    config_file = found.file,
    mode = 'config',
  })
end

---@return perforated.Workspace
local function env_ws()
  local ws = workspace.get_or_create({
    key = env.root,
    anchor = env.root,
    mode = 'env',
    root = env.root,
  })
  if not ws.info and env.info then
    ws:_set_info(env.info)
  end
  return ws
end

---@param ws perforated.Workspace
---@param buf integer
local function bind(ws, buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  ws:attach(buf)
  -- Learn client/root/case in the background; the first buffer pays, the rest share it.
  ws:ensure_info(function() end, require('perforated.core.queue').PRIORITY.background)
  require('perforated.buffer').attach(ws, buf)
  require('perforated.poll').start(ws)
end

local function flush_env_pending()
  local pending = env.pending
  env.pending = {}
  if env.state ~= 'ready' then
    return
  end
  for _, p in ipairs(pending) do
    if workspace.is_under(env.root, p.path, env.icase) then
      bind(env_ws(), p.buf)
    end
  end
end

---@param dir string a directory with no P4CONFIG above it (so cwd can't change the connection)
local function start_env_probe(dir)
  env.state = 'pending'
  local ctx = workspace.connection()
  ctx:run({ 'info' }, {
    priority = require('perforated.core.queue').PRIORITY.background,
    key = 'env-info',
    probe = true,
    cwd = dir,
  }, function(res)
    local rec = res.ok and res.records[1]
    if rec and rec.clientName and rec.clientName ~= '*unknown*' and rec.clientRoot then
      env.state = 'ready'
      env.root = workspace.normalize(rec.clientRoot)
      env.icase = rec.caseHandling == 'insensitive'
      env.info = rec
    else
      env.state = 'none'
    end
    flush_env_pending()
    local waiters = env.waiters or {}
    env.waiters = nil
    for _, w in ipairs(waiters) do
      w()
    end
  end)
end

--- Called by the gate for a real file buffer.
---@param buf integer
---@param path string absolute file path
---@param found perforated.GateHit|false
function M.attach(buf, path, found)
  if found then
    return bind(config_ws(found), buf)
  end
  if env.state == 'ready' then
    if workspace.is_under(env.root, path, env.icase) then
      bind(env_ws(), buf)
    end
  elseif env.state == 'unknown' or env.state == 'pending' then
    env.pending[#env.pending + 1] = { buf = buf, path = path }
    if env.state == 'unknown' then
      start_env_probe(vim.fs.dirname(path))
    end
  end
end

--- Workspace for a directory (no buffer), or nil. May create the workspace.
---@param dir string
---@return perforated.Workspace?
function M.for_dir(dir)
  local found = gate().lookup(dir)
  if found then
    return config_ws(found)
  end
  if env.state == 'ready' and workspace.is_under(env.root, dir, env.icase) then
    return env_ws()
  end
  return nil
end

--- Async variant of `for_dir` that also resolves environment-only setups (one `p4 info`).
---@param dir string
---@param cb fun(ws: perforated.Workspace?)
function M.resolve(dir, cb)
  local ws = M.for_dir(dir)
  if ws or gate().lookup(dir) or not require('perforated.core.env').has_env_client() then
    return cb(ws)
  end
  if env.state == 'ready' or env.state == 'none' then
    return cb(M.for_dir(dir))
  end
  env.waiters = env.waiters or {}
  table.insert(env.waiters, function()
    cb(M.for_dir(dir))
  end)
  if env.state == 'unknown' then
    start_env_probe(dir)
  end
end

--- Forget cached activation decisions (`:P4 refresh!`, tests).
function M.reset()
  env = { state = 'unknown', pending = {}, icase = false }
  local g = package.loaded['perforated.gate']
  if g then
    g.reset()
  end
end

return M
