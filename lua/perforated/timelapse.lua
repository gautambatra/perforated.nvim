--- Time-lapse engine: every revision of a file from two p4 calls.
---
--- `annotate -a` lists every line that ever existed in the file, in order, with the revision
--- range it lived in (`lower`..`upper`). Revision N is the lines with lower ≤ N ≤ upper, so any
--- revision is rebuilt in memory in O(lines) — no p4 call per step. Lines added at N have
--- lower = N; lines deleted at N have upper = N-1. An entry's index in the table is its identity,
--- which keeps the cursor on the same line across steps.

local parse = require('perforated.core.parse')

local M = {}

M.CACHE = 8 -- rebuilt revisions kept per time-lapse

---@class perforated.TlEntry
---@field text string
---@field lo integer
---@field hi integer

---@class perforated.Timelapse
---@field depotFile string
---@field revs table<integer, table>   rev → { rev, change, action, user, time, desc, client }
---@field first integer
---@field last integer                 newest revision that has content
---@field head integer
---@field entries perforated.TlEntry[]
---@field cache { n: integer, lines: string[], idx: integer[] }[]

--- Parse `annotate -a` records into entries (long lines arrive in several chunks).
---@param records table[]
---@return perforated.TlEntry[]
function M.parse(records)
  local entries, n = {}, 0
  local open -- a line whose chunks haven't ended yet
  for i = 1, #records do
    local r = records[i]
    local d = r.data
    if d then
      if open then
        open.text = open.text .. d
      else
        open = { text = d, lo = tonumber(r.lower) or 0, hi = tonumber(r.upper) or 0 }
      end
      if d:byte(-1) == 10 then
        local t = open.text:sub(1, -2)
        if t:byte(-1) == 13 then
          t = t:sub(1, -2)
        end
        open.text = t
        n = n + 1
        entries[n] = open
        open = nil
      end
    end
  end
  if open then
    n = n + 1
    entries[n] = open
  end
  return entries
end

local function deleted(action)
  return action == 'delete' or action == 'move/delete' or action == 'purge'
end

--- Load a file's time-lapse: `filelog -l` (revision metadata), then `annotate -a` of the newest
--- revision with content.
---@param ws perforated.Workspace
---@param path string  depot or local path (no revision)
---@param cb fun(tl: perforated.Timelapse?, err: string?)
function M.load(ws, path, cb)
  ws:run({ 'filelog', '-l', path }, {}, function(res)
    local rec = res.records[1]
    if not rec or not rec.depotFile then
      return cb(nil, res.errors[1] or ('no history for ' .. path))
    end
    local revs, first, head, last = {}, nil, 0, nil
    local fields = { 'rev', 'change', 'action', 'user', 'time', 'desc', 'client', 'fileSize' }
    for _, r in ipairs(parse.indexed(rec, fields)) do
      local n = tonumber(r.rev)
      if n then
        r.n = n
        revs[n] = r
        first = math.min(first or n, n)
        head = math.max(head, n)
        if not deleted(r.action) and (not last or n > last) then
          last = n
        end
      end
    end
    if not last then
      return cb(nil, rec.depotFile .. ' has no revision with content')
    end
    local max = require('perforated.config').get().timelapse.max_bytes
    local size = tonumber(revs[last].fileSize)
    if max and size and size > max then
      return cb(
        nil,
        ('%s is too large for time-lapse (%d MB); use its history (L)'):format(
          rec.depotFile,
          math.floor(size / 1048576)
        )
      )
    end
    ws:run({ 'annotate', '-a', '-q', rec.depotFile .. '#' .. last }, { timeout = 0 }, function(ares)
      if not ares.ok and #ares.records == 0 then
        return cb(nil, ares.errors[1] or 'annotate failed')
      end
      cb({
        depotFile = rec.depotFile,
        revs = revs,
        first = first,
        last = last,
        head = head,
        entries = M.parse(ares.records),
        cache = {},
      })
    end)
  end)
end

--- Revision N: its lines, and each line's entry index.
---@param tl perforated.Timelapse
---@param n integer
---@return string[] lines, integer[] idx
function M.revision(tl, n)
  for i, c in ipairs(tl.cache) do
    if c.n == n then
      if i > 1 then
        table.remove(tl.cache, i)
        table.insert(tl.cache, 1, c)
      end
      return c.lines, c.idx
    end
  end
  local lines, idx, k = {}, {}, 0
  local r = tl.revs[n]
  if not (r and deleted(r.action)) then
    local entries = tl.entries
    for i = 1, #entries do
      local e = entries[i]
      if e.lo <= n and n <= e.hi then
        k = k + 1
        lines[k] = e.text
        idx[k] = i
      end
    end
  end
  table.insert(tl.cache, 1, { n = n, lines = lines, idx = idx })
  tl.cache[M.CACHE + 1] = nil
  return lines, idx
end

--- Lines added at N (line numbers) and lines deleted at N, grouped by the line they'd sit above
--- (key 0 = after the last line). One pass over the entries.
---@param tl perforated.Timelapse
---@param n integer
---@return integer[] added, table<integer, string[]> removed  line → texts shown above it
function M.changes(tl, n)
  local added, removed = {}, {}
  local r = tl.revs[n]
  if r and deleted(r.action) then
    return added, removed
  end
  local entries, l, pending = tl.entries, 0, nil
  local track_removed = n > (tl.first or 1)
  for i = 1, #entries do
    local e = entries[i]
    if e.lo <= n and n <= e.hi then
      l = l + 1
      if e.lo == n then
        added[#added + 1] = l
      end
      if pending then
        removed[l] = pending
        pending = nil
      end
    elseif track_removed and e.hi == n - 1 then
      pending = pending or {}
      pending[#pending + 1] = e.text
    end
  end
  if pending then
    removed[0] = pending
  end
  return added, removed
end

--- Range mode: revision `b` with everything that changed after revision `a` — its lines added
--- after `a` (with the revision that added them) and the lines deleted after `a` (with the
--- revision that deleted them), grouped by the line of `b` they'd sit above (0 = the end).
---@param tl perforated.Timelapse
---@param a integer
---@param b integer
---@return { [1]: integer, [2]: integer }[] added  { line, rev }
---@return table<integer, { text: string, rev: integer }[]> removed
function M.range(tl, a, b)
  local added, removed, pending = {}, {}, nil
  local entries, l = tl.entries, 0
  for i = 1, #entries do
    local e = entries[i]
    if e.lo <= b and b <= e.hi then
      l = l + 1
      if e.lo > a then
        added[#added + 1] = { l, e.lo }
      end
      if pending then
        removed[l] = pending
        pending = nil
      end
    elseif e.hi >= a and e.hi < b and e.lo <= b then
      pending = pending or {}
      pending[#pending + 1] = { text = e.text, rev = e.hi + 1 }
    end
  end
  if pending then
    removed[0] = pending
  end
  return added, removed
end

--- Everything a step from revision `from` to `to` needs, in one pass over the entries:
--- the buffer edits (applied top-down, in order; adjacent revisions usually differ by a few
--- lines, so this is far cheaper than replacing the buffer), where line `lnum` of `from` ends
--- up, and `to`'s added / removed lines (as M.changes).
---@param tl perforated.Timelapse
---@param from integer
---@param to integer
---@param lnum integer
---@return { start: integer, del: integer, ins: string[] }[] edits  start is 0-based
---@return integer anchor  line in `to`
---@return integer[] added
---@return table<integer, string[]> removed
function M.transition(tl, from, to, lnum)
  local entries = tl.entries
  local edits, ne = {}, 0
  local pos = 0 -- line index in the buffer as the edits are applied
  local del, ins, run_start = 0, nil, -1
  local fl, tn = 0, 0 -- lines of `from` / `to` seen
  local anchor, want_next = nil, false
  local added, removed, pending = {}, {}, nil
  local track_removed = to > (tl.first or 1)
  local prev = to - 1
  for i = 1, #entries do
    local e = entries[i]
    local lo, hi = e.lo, e.hi
    local in_from = lo <= from and from <= hi
    local in_to = lo <= to and to <= hi
    if in_to then
      tn = tn + 1
      if lo == to then
        added[#added + 1] = tn
      end
      if pending then
        removed[tn] = pending
        pending = nil
      end
      if want_next then
        anchor, want_next = tn, false
      end
    elseif track_removed and hi == prev then
      if pending then
        pending[#pending + 1] = e.text
      else
        pending = { e.text }
      end
    end
    if in_from then
      fl = fl + 1
      if fl == lnum then
        if in_to then
          anchor = tn
        else
          want_next = true
        end
      end
      if in_to then
        if run_start >= 0 then
          ne = ne + 1
          edits[ne] = { start = run_start, del = del, ins = ins or {} }
          pos = run_start + (ins and #ins or 0)
          del, ins, run_start = 0, nil, -1
        end
        pos = pos + 1
      else
        if run_start < 0 then
          run_start = pos
        end
        del = del + 1
      end
    elseif in_to then
      if run_start < 0 then
        run_start = pos
      end
      if ins then
        ins[#ins + 1] = e.text
      else
        ins = { e.text }
      end
    end
  end
  if run_start >= 0 then
    ne = ne + 1
    edits[ne] = { start = run_start, del = del, ins = ins or {} }
  end
  if pending then
    removed[0] = pending
  end
  return edits, math.max(1, math.min(anchor or tn, tn)), added, removed
end

--- Where the cursor goes when moving from revision `from` (line `lnum`) to revision `to`: the
--- same entry if it exists there, else the nearest following one, else the nearest before.
---@param tl perforated.Timelapse
---@param from integer
---@param lnum integer
---@param to integer
---@return integer
function M.anchor(tl, from, lnum, to)
  local _, fidx = M.revision(tl, from)
  local _, tidx = M.revision(tl, to)
  if #tidx == 0 then
    return 1
  end
  local target = fidx[lnum]
  if not target then
    return math.min(lnum, #tidx)
  end
  local best_after, best_before
  for l, i in ipairs(tidx) do
    if i == target then
      return l
    elseif i > target and not best_after then
      best_after = l
    elseif i < target then
      best_before = l
    end
  end
  return best_after or best_before or 1
end

--- Previous / next revision that exists (revision numbers can have gaps after obliterates).
---@param tl perforated.Timelapse
---@param n integer
---@param dir integer  -1 | 1
---@return integer?
function M.step(tl, n, dir)
  local k = n + dir
  while k >= tl.first and k <= tl.head do
    if tl.revs[k] then
      return k
    end
    k = k + dir
  end
  return nil
end

return M
