--- Per-buffer state and the attach pipeline.
---
---   attach → (30 ms coalescing window) → one batched `fstat -x -` for all queued buffers of the
---   workspace → status → (opened) base text via `p4 print` (cached, immutable) → in-process
---   diff → signs + statusline. Edits re-diff locally (debounced), never calling p4.
---
--- Only buffer-specific data lives here; fstat records are shared on the Workspace.

local p4 = require('perforated.p4')
local engine = require('perforated.diff.engine')
local config = require('perforated.config')
local dbg = require('perforated.core.debug')

local M = {}

---@alias perforated.BufStatus 'pending'|'unmanaged'|'new'|'clean'|'opened'|'binary'

---@class perforated.BufState
---@field buf integer
---@field ws perforated.Workspace
---@field path string
---@field key string          case-normalised path (workspace cache key)
---@field status perforated.BufStatus
---@field rec table?          fstat record (shared object from ws.fstat)
---@field base string[]?      base lines (nil = none loaded; {} = empty base)
---@field base_text string?   base joined for the diff engine (cached: the base never changes)
---@field base_spec string|false|nil
---@field hunks perforated.Hunk[]
---@field gen integer         diff generation (drops stale async results)
---@field timer uv.uv_timer_t?
---@field lines_attached boolean
---@field too_big boolean?

local states = {} ---@type table<integer, perforated.BufState>
local group ---@type integer

---@param buf integer
---@return perforated.BufState?
function M.get(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return states[buf]
end

-- ---------------------------------------------------------------------------------------------
-- fstat batching (per workspace)
-- ---------------------------------------------------------------------------------------------

local batches = {} ---@type table<string, { paths: table<string, true>, timer: boolean }>

M.BATCH_MS = 30

---@param ws perforated.Workspace
local function flush(ws)
  local b = batches[ws.key]
  batches[ws.key] = nil
  if not b then
    return
  end
  local paths = vim.tbl_keys(b.paths)
  table.sort(paths)
  dbg.debug('buffer', 'fstat batch of %d path(s) for %s', #paths, ws.key)
  p4.fstat(ws, paths, { priority = 2 }, function(r)
    if not r.res.ok and next(r.files) == nil and next(r.missing) == nil then
      return -- connection trouble; conn state/statusline already reflect it
    end
    for i, path in ipairs(paths) do
      local k = p4.key(ws, path)
      local pos = r.by_index[i] or {}
      local rec = r.files[k] or pos.rec
      local missing = r.missing[k] or pos.missing
      ws.fstat[k] = rec
      for buf, st in pairs(states) do
        if st.ws == ws and st.key == k then
          M.apply(buf, rec, missing)
        end
      end
    end
  end)
end

--- Queue a (re-)fstat of a buffer's file.
---@param buf integer
function M.refresh(buf)
  local st = states[buf]
  if not st then
    return
  end
  local b = batches[st.ws.key]
  if not b then
    b = { paths = {} }
    batches[st.ws.key] = b
    local ws = st.ws
    vim.defer_fn(function()
      flush(ws)
    end, M.BATCH_MS)
  end
  b.paths[st.path] = true
end

-- ---------------------------------------------------------------------------------------------
-- Status transitions
-- ---------------------------------------------------------------------------------------------

---@param st perforated.BufState
local function status_changed(st)
  require('perforated.status').update(st.buf)
end

--- Apply a fresh fstat result to a buffer.
---@param buf integer
---@param rec table?
---@param missing string?
function M.apply(buf, rec, missing)
  local st = states[buf]
  if not st then
    return
  end
  st.rec = rec
  local prev = st.status
  if rec then
    if rec.action then
      st.status = p4.is_text(rec) and 'opened' or 'binary'
    else
      st.status = 'clean'
    end
  elseif missing == 'nosuch' then
    st.status = 'new' -- inside the client view but not in the depot: candidate for add
  else
    st.status = 'unmanaged' -- not in the client view (or unknown): stay out of the way
  end

  if dbg.enabled then
    dbg.debug(
      'buffer',
      'buf %d %s: %s -> %s (action=%s change=%s have=%s head=%s type=%s missing=%s)',
      buf,
      st.path,
      prev,
      st.status,
      tostring(rec and rec.action),
      tostring(rec and rec.change),
      tostring(rec and rec.haveRev),
      tostring(rec and rec.headRev),
      tostring(rec and (rec.type or rec.headType)),
      tostring(missing)
    )
  end
  if st.status == 'opened' then
    M.load_base(buf)
  else
    st.base, st.base_text, st.base_spec, st.hunks = nil, nil, nil, {}
    require('perforated.signs').render(buf, {})
  end

  local co = require('perforated.checkout')
  co.on_status(buf, prev, st.status)
  status_changed(st)
end

--- Fetch the base text for an opened buffer (cached per immutable revision).
---@param buf integer
function M.load_base(buf)
  local st = states[buf]
  if not st or not st.rec then
    return
  end
  local spec = p4.base_spec(st.rec) or false
  if st.base and st.base_spec == spec then
    return M.update(buf)
  end
  st.base_spec = spec
  if not spec then
    st.base, st.base_text = {}, ''
    return M.update(buf)
  end
  p4.print(st.ws, spec, { priority = 2 }, function(lines, err)
    local cur = states[buf]
    if not cur or cur.base_spec ~= spec then
      return
    end
    if not lines then
      cur.base = nil
      dbg.error('buffer', 'buf %d: base %s failed: %s', buf, spec, tostring(err))
      return vim.notify_once('[perforated] could not load base for diff: ' .. tostring(err))
    end
    dbg.debug('buffer', 'buf %d: base %s loaded (%d lines)', buf, spec, #lines)
    cur.base = lines
    cur.base_text = engine.join(lines)
    M.update(buf)
  end)
end

--- Re-diff the buffer against its base and render. Cheap for normal files; large files are
--- diffed on a worker thread; files beyond `signs.hard_max` get no signs.
---@param buf integer
function M.update(buf)
  local st = states[buf]
  if not st or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local cfg = config.get().signs
  if not st.base or not cfg.enabled then
    st.hunks = {}
    require('perforated.signs').render(buf, {})
    return status_changed(st)
  end
  local n = vim.api.nvim_buf_line_count(buf)
  st.too_big = n > cfg.hard_max
  if st.too_big then
    st.hunks = {}
    require('perforated.signs').render(buf, {})
    return status_changed(st)
  end
  st.gen = st.gen + 1
  local gen = st.gen
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local t0 = dbg.enabled and vim.uv.hrtime()
  local function done(hunks)
    local cur = states[buf]
    if not cur or cur.gen ~= gen then
      return
    end
    if t0 and dbg.on('trace') then
      dbg.trace(
        'buffer',
        'buf %d: diff %d lines -> %d hunks in %.2fms%s',
        buf,
        n,
        #hunks,
        (vim.uv.hrtime() - t0) / 1e6,
        n > cfg.max_lines and ' (worker)' or ''
      )
    end
    cur.hunks = hunks
    require('perforated.signs').render(buf, hunks)
    status_changed(cur)
  end
  local base = st.base_text or st.base
  if n > cfg.max_lines or #st.base > cfg.max_lines then
    engine.hunks_async(base, lines, done)
  else
    done(engine.hunks(base, lines))
  end
end

---@param buf integer
local function schedule_update(buf)
  local st = states[buf]
  if not st or not st.base then
    return
  end
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(M.DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      M.update(buf)
    end)
  end)
end

M.DEBOUNCE_MS = 100

-- Shared by every attached buffer (callbacks receive the buffer number): no closures per buffer.
local ATTACH_CALLBACKS = {
  on_lines = function(_, buf)
    if not states[buf] then
      return true -- detach
    end
    schedule_update(buf)
  end,
  on_reload = function(_, buf)
    schedule_update(buf)
  end,
}

-- ---------------------------------------------------------------------------------------------
-- Attach / detach
-- ---------------------------------------------------------------------------------------------

local function ensure_group()
  if group then
    return
  end
  require('perforated.hl').setup()
  group = vim.api.nvim_create_augroup('perforated.buffer', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = group,
    callback = function(ev)
      M.detach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if states[ev.buf] then
        require('perforated.status').on_enter(ev.buf)
      end
    end,
  })
end

---@param ws perforated.Workspace
---@param buf integer
function M.attach(ws, buf)
  if states[buf] then
    return
  end
  ensure_group()
  local path = vim.api.nvim_buf_get_name(buf)
  states[buf] = {
    buf = buf,
    ws = ws,
    path = path,
    key = p4.key(ws, path),
    status = 'pending',
    hunks = {},
    gen = 0,
    lines_attached = false,
  }
  vim.api.nvim_buf_attach(buf, false, ATTACH_CALLBACKS)
  states[buf].lines_attached = true
  require('perforated.checkout').attach(buf)
  if config.get().keymaps == 'default' then
    require('perforated.keymaps').attach(buf)
  end
  if config.get().blame_line.enabled then
    require('perforated.blame').setup()
  end
  M.refresh(buf)
end

---@param buf integer
function M.detach(buf)
  local st = states[buf]
  if not st then
    return
  end
  states[buf] = nil
  if st.timer then
    st.timer:stop()
    st.timer:close()
  end
  pcall(require('perforated.signs').render, buf, {})
end

--- Recompute cache keys after the workspace learned its case handling.
---@param ws perforated.Workspace
function M.rekey(ws)
  for _, st in pairs(states) do
    if st.ws == ws then
      st.key = p4.key(ws, st.path)
    end
  end
end

--- All states (for workspace-wide operations such as polling).
---@return table<integer, perforated.BufState>
function M.all()
  return states
end

function M._reset()
  for buf in pairs(states) do
    M.detach(buf)
  end
  batches = {}
end

return M
