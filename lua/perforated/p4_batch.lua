--- Snapshots of printed content and prints of several files in one call: the diff tab, the
--- identical-files check and the lists use them, so they load with those, not at startup.
--- `perforated.p4` forwards to them; `p4.print` waits on a batch in flight here.

local p4 = require('perforated.p4')

local M = {}

---@class perforated.Snapshot
---@field id integer
---@field lines table<string, string[]>  spec → content
---@field cached string[]  content-cache keys added while printing for it
---@field closed boolean?  released: nothing more is kept

local snapshots = 0

--- A snapshot of mutable specs (`@=N`, `#head`): each prints once, then reads keep that
--- content. The diff tab keeps one, so its files print once however often they are shown.
---@return perforated.Snapshot
function M.snapshot()
  snapshots = snapshots + 1
  return { id = snapshots, lines = {}, cached = {} }
end

--- Drop a snapshot's content and the cached revisions printed for it (a closed diff tab).
---@param snap perforated.Snapshot
function M.release(snap)
  local cache = require('perforated.core.cache').content()
  for _, k in ipairs(snap.cached) do
    cache:delete(k)
  end
  snap.lines, snap.cached, snap.closed = {}, {}, true
end

--- A fresh snapshot in place of `snap` (a refresh): mutable specs print again, while the
--- revisions cached for `snap` stay cached and still go when the new one is released.
---@param snap perforated.Snapshot
---@return perforated.Snapshot
function M.renew(snap)
  local fresh = M.snapshot()
  fresh.cached = snap.cached
  snap.lines, snap.cached, snap.closed = {}, {}, true
  return fresh
end

--- Whether a `print` header record is the file `spec` names: same depot path, and the same
--- revision (`#N`) or shelf (`@=N`) when the spec names one.
---@param spec string
---@param rec table
---@return boolean
local function header_is(spec, rec)
  local path, rest = spec:match('^(.-)([#@].*)$')
  if (path or spec) ~= rec.depotFile then
    return false
  end
  local rev = rest and rest:match('^#(%d+)$')
  local shelf = rest and rest:match('^@=(%d+)$')
  return (not rev or rev == rec.rev) and (not shelf or shelf == rec.change)
end

--- Print several revision specs in one call (`-x - print`), keeping each as `print` would (the
--- content cache, or `opts.snapshot`). A `print` of one of them meanwhile waits for this answer.
--- p4 answers in the order asked and skips files it can't print, so each header is matched to
--- the next spec it names; a spec without an answer is printed alone when it's asked for.
--- `opts.budget` ({ bytes = n }, shared by the batches it's given to): keep only that much
--- content (in the order asked), the rest only passed to `cb`.
---@param ws perforated.Workspace
---@param specs string[]
---@param opts (perforated.RunOpts|{ snapshot: perforated.Snapshot?, budget: { bytes: integer }? })?
---@param cb fun(got: table<string, string[]>)?  spec → lines
function M.print_batch(ws, specs, opts, cb)
  local snap = opts and opts.snapshot
  local budget = opts and opts.budget
  local keys = {}
  for i, spec in ipairs(specs) do
    keys[i] = ws:server_key() .. '|' .. spec
    p4._batched[keys[i]] = p4._batched[keys[i]] or {}
  end
  opts = vim.tbl_extend('force', { stdin = specs }, opts or {})
  opts.globals = { '-x', '-' }
  opts.snapshot, opts.budget = nil, nil
  ws:run({ 'print', '-q' }, opts, function(res)
    local got, sizes = {}, {}
    local cur, chunks, next_i = nil, {}, 1
    local function flush()
      if cur then
        local text = table.concat(chunks)
        got[cur], sizes[cur] = p4.split_lines(text), #text
      end
      cur, chunks = nil, {}
    end
    for _, rec in ipairs(res.records) do
      if rec.depotFile then
        flush()
        for i = next_i, #specs do
          if header_is(specs[i], rec) then
            cur, next_i = specs[i], i + 1
            break
          end
        end
      elseif rec.data and cur then
        chunks[#chunks + 1] = rec.data
      end
    end
    flush()
    for i, spec in ipairs(specs) do
      if got[spec] and (not budget or sizes[spec] <= budget.bytes) then
        if budget then
          budget.bytes = budget.bytes - sizes[spec]
        end
        p4._keep(ws, spec, got[spec], sizes[spec], snap)
      end
      local waiting = p4._batched[keys[i]] or {}
      p4._batched[keys[i]] = nil
      for _, fn in ipairs(waiting) do
        fn(got[spec])
      end
    end
    if cb then
      cb(got)
    end
  end)
end

return M
