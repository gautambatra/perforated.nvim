--- Caches. Everything is in-process memory and therefore per Neovim session.
---
--- * `M.lru(max_bytes)` — byte-accounted LRU, used for immutable revision content
---   (`<server>|//depot/path#rev` → string). Shared across the workspaces of one session.
--- * Per-workspace caches (fstat, CL memo) live on the Workspace object.

local M = {}

---@class perforated.LRU
---@field max integer bytes
---@field size integer bytes currently held
---@field map table<string, table> key → node
---@field head table sentinel (most recent after head)
local LRU = {}
LRU.__index = LRU

---@param max_bytes integer
---@return perforated.LRU
function M.lru(max_bytes)
  local head = {}
  head.next, head.prev = head, head
  return setmetatable({ max = max_bytes, size = 0, map = {}, head = head, n = 0 }, LRU)
end

local function unlink(node)
  node.prev.next = node.next
  node.next.prev = node.prev
end

function LRU:_push_front(node)
  local head = self.head
  node.next, node.prev = head.next, head
  head.next.prev = node
  head.next = node
end

---@param key string
---@return any
function LRU:get(key)
  local node = self.map[key]
  if not node then
    return nil
  end
  unlink(node)
  self:_push_front(node)
  return node.value
end

---@param key string
---@return boolean
function LRU:has(key)
  return self.map[key] ~= nil
end

---@param key string
---@param value string|table
---@param bytes integer? defaults to #value for strings
function LRU:set(key, value, bytes)
  bytes = bytes or (type(value) == 'string' and #value or 0)
  if bytes > self.max then
    -- Never cache something larger than the whole budget.
    self:delete(key)
    return
  end
  local node = self.map[key]
  if node then
    self.size = self.size - node.bytes
    unlink(node)
  else
    node = { key = key }
    self.map[key] = node
    self.n = self.n + 1
  end
  node.value, node.bytes = value, bytes
  self.size = self.size + bytes
  self:_push_front(node)
  while self.size > self.max do
    local lru = self.head.prev
    self:delete(lru.key)
  end
end

---@param key string
function LRU:delete(key)
  local node = self.map[key]
  if not node then
    return
  end
  unlink(node)
  self.map[key] = nil
  self.size = self.size - node.bytes
  self.n = self.n - 1
end

function LRU:clear()
  self.map = {}
  self.head.next, self.head.prev = self.head, self.head
  self.size, self.n = 0, 0
end

local content ---@type perforated.LRU?

--- Session-wide revision content cache (`<server>|<depotFile>#<rev>` → text).
---@return perforated.LRU
function M.content()
  if not content then
    local mb = require('perforated.config').get().cache.content_mb
    content = M.lru(mb * 1024 * 1024)
  end
  return content
end

function M._reset()
  content = nil
end

return M
