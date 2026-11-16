--- `:P4` argument completion (loaded with the first <Tab> on a `:P4` command's arguments).
---
--- Command-line completion is synchronous, so it never waits long on p4:
---   * changelist numbers come only from what the plugin already knows (this client's pending
---     changelists and their shelves, the opened files, the client view's recent submits);
---   * depot paths (`//…`) ask `p4 dirs` + `p4 files -e` for the directory, kept 5 minutes;
---     users ask `p4 users` once per connection. A `<Tab>` waits at most `complete.wait` ms
---     for an answer it doesn't have yet: a slower one shows on the next `<Tab>` (the call
---     keeps running). Offline, p4 isn't asked at all.

local M = {}

--- How long a directory's listing is kept (ms).
M.TTL_MS = 5 * 60 * 1000

local dirs = {} ---@type table<string, { t: integer, items: string[] }>
local users = {} ---@type table<string, string[]>
local pending = {} ---@type table<string, true>

---@return perforated.Workspace?
local function workspace()
  return require('perforated').workspace()
end

---@param ws perforated.Workspace
local function online(ws)
  return ws.conn == nil or ws.conn.state == 'online'
end

--- Wait (at most `complete.wait` ms) for `key`'s call to answer.
---@param key string
local function wait_for(key)
  local ms = (require('perforated.config').get().complete or {}).wait or 300
  if pending[key] and ms > 0 then
    vim.wait(ms, function()
      return not pending[key]
    end, 10)
  end
end

--- A space in a path is `\ ` on the command line (`:P4` splits its arguments on the others).
---@param s string
local function escape(s)
  return (s:gsub('([\\ ])', '\\%1'))
end

-- ---------------------------------------------------------------------------------------------
-- Changelists
-- ---------------------------------------------------------------------------------------------

---@param set table<string, true>
---@return string[]  newest first
local function sorted(set)
  local out = vim.tbl_keys(set)
  table.sort(out, function(a, b)
    return (tonumber(a) or 0) > (tonumber(b) or 0)
  end)
  return out
end

--- Changelist numbers the plugin knows: `kind` 'pending' | 'shelved' | 'submitted' | 'any'.
---@param ws perforated.Workspace?
---@param kind string
---@return string[]
function M.changes(ws, kind)
  local set = {}
  if not ws then
    return {}
  end
  if kind ~= 'submitted' then
    for _, r in ipairs((ws.pending_kept or {}).records or {}) do
      if r.change and (kind ~= 'shelved' or r.shelved ~= nil) then
        set[tostring(r.change)] = true
      end
    end
    if kind ~= 'shelved' then
      for _, r in pairs(ws.opened or {}) do
        if r.change and r.change ~= 'default' then
          set[tostring(r.change)] = true
        end
      end
    end
  end
  if kind == 'submitted' or kind == 'any' then
    local client = package.loaded['perforated.views.client'] -- only if the view was opened
    local view = client and client._get and client._get(ws.key)
    for _, c in ipairs((view and view.data or {}).submitted or {}) do
      if c.change then
        set[tostring(c.change)] = true
      end
    end
  end
  return sorted(set)
end

-- ---------------------------------------------------------------------------------------------
-- Depot paths and users
-- ---------------------------------------------------------------------------------------------

--- Depot paths under `arglead`'s directory (`//` alone: the depots).
---@param ws perforated.Workspace?
---@param arglead string  starts with `//`; `\ ` for a space
---@return string[]
function M.depot(ws, arglead)
  if not ws then
    return {}
  end
  local word = arglead:gsub('\\(.)', '%1')
  local dir = word:match('^(//.*/)') or '//'
  local key = ws.key .. '\0' .. dir
  local hit = dirs[key]
  if (not hit or vim.uv.now() - hit.t > M.TTL_MS) and not pending[key] and online(ws) then
    pending[key] = true
    local pat = dir == '//' and '//*' or (dir .. '*')
    local items, left = {}, dir == '//' and 1 or 2
    local function done()
      left = left - 1
      if left == 0 then
        table.sort(items)
        dirs[key] = { t = vim.uv.now(), items = items }
        pending[key] = nil
      end
    end
    local opts = { priority = 1, timeout = 0 }
    ws:run({ 'dirs', pat }, opts, function(res)
      for _, r in ipairs(res.records) do
        if r.dir then
          items[#items + 1] = r.dir .. '/'
        end
      end
      done()
    end)
    if dir ~= '//' then
      ws:run({ 'files', '-e', pat }, opts, function(res)
        for _, r in ipairs(res.records) do
          if r.depotFile then
            items[#items + 1] = r.depotFile
          end
        end
        done()
      end)
    end
  end
  wait_for(key)
  return vim.tbl_map(escape, (dirs[key] or {}).items or {})
end

--- The server's users (`p4 users`, once per server and user).
---@param ws perforated.Workspace?
---@return string[]
function M.users(ws)
  if not ws then
    return {}
  end
  local s = ws.settings or {}
  local key = 'users\0' .. (s.P4PORT or '') .. '\0' .. (s.P4USER or '')
  if not users[key] and not pending[key] and online(ws) then
    pending[key] = true
    ws:run({ 'users' }, { priority = 1, timeout = 0 }, function(res)
      local out = {}
      for _, r in ipairs(res.records) do
        if r.User then
          out[#out + 1] = r.User
        end
      end
      table.sort(out)
      users[key] = res.ok and out or nil
      pending[key] = nil
    end)
  end
  wait_for(key)
  return users[key] or {}
end

-- ---------------------------------------------------------------------------------------------
-- Per command
-- ---------------------------------------------------------------------------------------------

---@class perforated.CompleteSpec
---@field flags string[]?     the command's flags
---@field words string[]?     fixed words (`new`, `default`)
---@field cl string?          a changelist argument: 'pending' | 'shelved' | 'submitted' | 'any'
---@field c string?           what `-c` takes: 'pending' (and `c_default`) | 'shelved'
---@field c_default boolean?  `-c default` is valid
---@field depot boolean?      `//…` depot paths
---@field files boolean?      local files

--- Candidates for `arglead`, the word after `prev` (nil: the first argument).
---@param spec perforated.CompleteSpec
---@param arglead string
---@param prev string?
---@return string[]
function M.complete(spec, arglead, prev)
  local ws = workspace()
  if prev == '-c' and spec.c then
    local out = M.changes(ws, spec.c)
    if spec.c_default then
      table.insert(out, 1, 'default')
    end
    return out
  elseif prev == '-u' then
    return M.users(ws)
  elseif prev == '-m' then
    return {}
  end
  if arglead:match('^%-') then
    return vim.deepcopy(spec.flags or {})
  end
  if spec.depot and arglead:match('^//') then
    return M.depot(ws, arglead)
  end
  local out = {}
  vim.list_extend(out, spec.words or {})
  if spec.cl then
    vim.list_extend(out, M.changes(ws, spec.cl))
  end
  if spec.files and not arglead:match('^%d+$') then
    vim.list_extend(out, vim.fn.getcompletion(arglead, 'file'))
  end
  return out
end

--- Calls still on their way (tests).
function M._pending_count()
  return vim.tbl_count(pending)
end

return M
