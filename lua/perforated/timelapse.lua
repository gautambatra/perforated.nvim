--- Time-lapse engine: every revision of a file from a few p4 calls.
---
--- `annotate -a` lists every line that ever existed in the file, in order, with the revision
--- range it lived in (`lower`..`upper`). Revision N is the lines with lower ≤ N ≤ upper, so any
--- revision is rebuilt in memory in O(lines) — no p4 call per step. Lines added at N have
--- lower = N; lines deleted at N have upper = N-1. A line's index is its identity, which keeps
--- the cursor on the same line across steps.
---
--- The server's cost is walking the file's revisions, so a long history loads in two parts:
--- the newest `timelapse.window` revisions first (`annotate -a file#J,#last`: lines older than
--- J come back with lower = J), then `file#first,#J` in the background. The two are stitched
--- on revision J, whose lines both list in the same order. A closed time-lapse is kept for a
--- while; reopening it after new submits annotates only the new revisions.
---
--- Lines are stored as three parallel arrays (`text`, `lo`, `hi`): a table per line costs
--- about 180 bytes on top of its text.

local parse = require('perforated.core.parse')

local M = {}

M.CACHE = 8 -- rebuilt revisions kept per time-lapse
M.KEEP = 2 -- closed time-lapses kept for a quick reopen
M.KEEP_BYTES = 5 * 1024 * 1024 -- larger ones (line text) aren't kept
M.KEEP_MS = 10 * 60 * 1000 -- a kept time-lapse is dropped after this long

---@class perforated.TlLines
---@field text string[]
---@field lo integer[]
---@field hi integer[]
---@field bytes integer  total text length

---@class perforated.Timelapse: perforated.TlLines
---@field depotFile string
---@field revs table<integer, table>   rev → { rev, change, action, user, time, desc, client }
---@field first integer
---@field last integer                 newest revision that has content
---@field head integer
---@field from integer                 oldest revision loaded (first once the history is in)
---@field sig string                   identity of revisions first..last (cache validation)
---@field key string                   cache key
---@field cache { n: integer, lines: string[], idx: integer[] }[]

local function strip(t)
  t = t:sub(1, -2)
  if t:byte(-1) == 13 then
    t = t:sub(1, -2)
  end
  return t
end

--- Parse `annotate -a` records into line arrays (long lines arrive in several chunks).
---@param records table[]
---@return perforated.TlLines
function M.parse(records)
  local text, los, his, n, bytes = {}, {}, {}, 0, 0
  local open, olo, ohi -- a line whose chunks haven't ended yet
  local function emit(t)
    n = n + 1
    text[n], los[n], his[n] = t, olo, ohi
    bytes = bytes + #t
    open = nil
  end
  for i = 1, #records do
    local r = records[i]
    local d = r.data
    if d then
      local lo, hi = tonumber(r.lower) or 0, tonumber(r.upper) or 0
      -- A revision's last line without a newline is a whole entry too: the next record's
      -- different range shows it isn't continued (a long line's chunks share one range).
      if open and (lo ~= olo or hi ~= ohi) then
        emit(open)
      end
      if open then
        open = open .. d
      else
        open, olo, ohi = d, lo, hi
      end
      if d:byte(-1) == 10 then
        emit(strip(open))
      end
    end
  end
  if open then
    emit(open)
  end
  return { text = text, lo = los, hi = his, bytes = bytes }
end

--- Join an annotate of revisions ..j (`a`) with one of j.. (`b`): the lines alive at j appear in
--- both, in the same order, and pair up (lower from `a`, upper from `b`). Lines that died before
--- j (only in `a`) and lines born after it (only in `b`) never share a revision, so either order
--- between two paired lines rebuilds every revision correctly.
---@param a perforated.TlLines
---@param b perforated.TlLines
---@param j integer
---@return perforated.TlLines? nil when the two don't agree on revision j
function M.stitch(a, b, j)
  local at, alo, ahi = a.text, a.lo, a.hi
  local bt, blo, bhi = b.text, b.lo, b.hi
  local na, nb = #at, #bt
  local text, los, his, n, bytes = {}, {}, {}, 0, 0
  local i, k = 1, 1
  while true do
    while i <= na and not (alo[i] <= j and j <= ahi[i]) do
      n = n + 1
      text[n], los[n], his[n] = at[i], alo[i], ahi[i]
      bytes = bytes + #at[i]
      i = i + 1
    end
    while k <= nb and not (blo[k] <= j and j <= bhi[k]) do
      n = n + 1
      text[n], los[n], his[n] = bt[k], blo[k], bhi[k]
      bytes = bytes + #bt[k]
      k = k + 1
    end
    if i > na and k > nb then
      break
    end
    if i > na or k > nb or at[i] ~= bt[k] then
      return nil
    end
    n = n + 1
    text[n], los[n], his[n] = at[i], alo[i], bhi[k]
    bytes = bytes + #at[i]
    i, k = i + 1, k + 1
  end
  return { text = text, lo = los, hi = his, bytes = bytes }
end

--- Line arrays from a list of `{ text, lo, hi }` (tests and the bench build time-lapses so).
---@param list { text: string, lo: integer, hi: integer }[]
---@return perforated.TlLines
function M.lines(list)
  local text, los, his, bytes = {}, {}, {}, 0
  for i, e in ipairs(list) do
    text[i], los[i], his[i] = e.text, e.lo, e.hi
    bytes = bytes + #e.text
  end
  return { text = text, lo = los, hi = his, bytes = bytes }
end

local deleted = require('perforated.history').deleted

--- Identity of revisions first..last: a kept time-lapse is only reused while it still matches.
---@param revs table<integer, table>
---@param first integer
---@param last integer
---@return string
function M.signature(revs, first, last)
  local parts = {}
  for n = first, last do
    local r = revs[n]
    if r then
      parts[#parts + 1] = ('%d:%s:%s:%s'):format(n, r.change or '', r.action or '', r.digest or '')
    end
  end
  return table.concat(parts, ' ')
end

-- Closed time-lapses, most recent first: { key, lines, first, last, sig, timer }.
local kept = {}

local function forget(i)
  local k = table.remove(kept, i)
  if k and k.timer then
    k.timer:stop()
    k.timer:close()
  end
  return k
end

---@param key string
---@return table?
local function find_kept(key)
  for i, k in ipairs(kept) do
    if k.key == key then
      return k, i
    end
  end
end

--- Keep a closed time-lapse for a quick reopen (only a complete one, and not a huge one).
---@param tl perforated.Timelapse
function M.keep(tl)
  if not tl.key or tl.from > tl.first or tl.bytes > M.KEEP_BYTES then
    return
  end
  local _, i = find_kept(tl.key)
  if i then
    forget(i)
  end
  local entry = {
    key = tl.key,
    lines = { text = tl.text, lo = tl.lo, hi = tl.hi, bytes = tl.bytes },
    first = tl.first,
    last = tl.last,
    sig = tl.sig,
  }
  local timer = vim.uv.new_timer()
  entry.timer = timer
  timer:start(
    M.KEEP_MS,
    0,
    vim.schedule_wrap(function()
      local _, at = find_kept(entry.key)
      if at and kept[at] == entry then
        forget(at)
      end
    end)
  )
  table.insert(kept, 1, entry)
  while #kept > M.KEEP do
    forget(#kept)
  end
end

--- Kept time-lapses (for tests).
---@return { key: string, first: integer, last: integer, bytes: integer }[]
function M.kept()
  return vim.tbl_map(function(k)
    return { key = k.key, first = k.first, last = k.last, bytes = k.lines.bytes }
  end, kept)
end

--- What to annotate for a file whose newest revision with content is `last`.
---@param kept_entry table?  a kept time-lapse of the file
---@param last integer
---@param first integer
---@param want integer?  a revision the window must hold (the one the view opens on)
---@return { kind: 'none'|'extend'|'full'|'window', spec: string?, j: integer? }
local function plan(kept_entry, last, first, want)
  if kept_entry and kept_entry.last == last then
    return { kind = 'none' }
  end
  if kept_entry and kept_entry.last < last then
    return { kind = 'extend', spec = ('#%d,#%d'):format(kept_entry.last, last), j = kept_entry.last }
  end
  local w = require('perforated.config').get().timelapse.window or 0
  local j = math.min(last - w + 1, want or last)
  if w <= 0 or j <= first then
    return { kind = 'full', spec = '#' .. last }
  end
  return { kind = 'window', spec = ('#%d,#%d'):format(j, last), j = j }
end

---@class perforated.TlLoadOpts
---@field head { rev: integer, action: string }?  the file's head (from fstat): the first annotate starts alongside filelog
---@field want integer?  a revision the first part must hold (the one the view opens on)
---@field on_more fun(tl: perforated.Timelapse?, err: string?)?  the older history arrived (or failed)

--- Load a file's time-lapse: `filelog -l` (revision metadata), then `annotate -a` of the newest
--- revision with content (its newest `timelapse.window` revisions first, the rest in the
--- background). `cb` gets the time-lapse as soon as the first part is in; `tl.from` says how
--- far back it goes, and `opts.on_more` runs once the rest is stitched on.
---@param ws perforated.Workspace
---@param path string  depot or local path (no revision)
---@param cb fun(tl: perforated.Timelapse?, err: string?)
---@param opts perforated.TlLoadOpts?
---@return { cancel: fun() } loader  cancel() stops the p4 calls still running (the view closed)
function M.load(ws, path, cb, opts)
  opts = opts or {}
  local loader = { cancelled = false, ctls = {} }
  function loader.cancel()
    loader.cancelled = true
    for ctl in pairs(loader.ctls) do
      ctl.cancel()
    end
    loader.ctls = {}
  end

  --- One `annotate -a` of a revision (range) of the depot file; returns its own cancel.
  ---@param depot string
  ---@param spec string
  ---@param prio integer?
  ---@param k fun(res: perforated.RunResult)
  ---@return { cancel: fun() }
  local function annotate(depot, spec, prio, k)
    local call = { cancelled = false }
    local ctl
    function call.cancel()
      call.cancelled = true
      if ctl then
        loader.ctls[ctl] = nil
        ctl.cancel()
      end
    end
    ws:run({ 'annotate', '-a', '-q', depot .. spec }, {
      timeout = 0,
      priority = prio,
      on_spawn = function(c)
        if loader.cancelled or call.cancelled then
          c.cancel()
        else
          ctl = c
          loader.ctls[c] = true
        end
      end,
    }, function(res)
      if ctl then
        loader.ctls[ctl] = nil
      end
      if not (loader.cancelled or call.cancelled) then
        k(res)
      end
    end)
    return call
  end

  local function failed(res)
    return not res.ok and #res.records == 0
  end

  local server = ws:server_key()
  local function key_of(depot)
    return server .. '|' .. depot
  end

  -- With the head known (the buffer's fstat), the first annotate runs alongside filelog.
  local early -- { spec, res?, waiting? }
  local depot0 = path:match('^//') and path
  local head = opts.head
  if depot0 and head and head.rev and head.rev > 0 and not deleted(head.action) then
    local p = plan(find_kept(key_of(depot0)), head.rev, 1, opts.want)
    if p.spec then
      local e = { spec = p.spec }
      early = e
      e.call = annotate(depot0, p.spec, nil, function(res)
        e.res = res
        if e.waiting then
          e.waiting(res)
        end
      end)
    end
  end

  -- A local name is escaped (`@` and `#` are literal there); a depot path already is.
  local arg = path:match('^//') and path or require('perforated.p4').escape(path)
  ws:run({ 'filelog', '-l', arg }, {}, function(res)
    if loader.cancelled then
      return
    end
    local rec = res.records[1]
    if not rec or not rec.depotFile then
      loader.cancel()
      return cb(nil, res.errors[1] or ('no history for ' .. path))
    end
    local depot = rec.depotFile
    local revs, first, head_rev, last = {}, nil, 0, nil
    local fields = {
      'rev',
      'change',
      'action',
      'user',
      'time',
      'desc',
      'client',
      'fileSize',
      'type',
      'digest',
    }
    for _, r in ipairs(parse.indexed(rec, fields)) do
      local n = tonumber(r.rev)
      if n then
        r.n = n
        revs[n] = r
        first = math.min(first or n, n)
        head_rev = math.max(head_rev, n)
        if not deleted(r.action) and (not last or n > last) then
          last = n
        end
      end
    end
    if not last then
      loader.cancel()
      return cb(nil, depot .. ' has no revision with content')
    end
    local max = require('perforated.config').get().timelapse.max_bytes
    local size = tonumber(revs[last].fileSize)
    if max and size and size > max then
      loader.cancel()
      return cb(
        nil,
        ('%s is too large for time-lapse (%d MB); use its history (L)'):format(
          depot,
          math.floor(size / 1048576)
        )
      )
    end

    local key = key_of(depot)
    local k = find_kept(key)
    if k and (k.first ~= first or M.signature(revs, first, k.last) ~= k.sig) then
      local _, i = find_kept(key)
      forget(i) -- an obliterate or a retype: annotate afresh
      k = nil
    end
    local tl = {
      depotFile = depot,
      revs = revs,
      first = first,
      last = last,
      head = head_rev,
      from = first,
      sig = M.signature(revs, first, last),
      key = key,
      cache = {},
    }
    local function set_lines(lines)
      tl.text, tl.lo, tl.hi, tl.bytes = lines.text, lines.lo, lines.hi, lines.bytes
      tl.cache = {}
    end
    -- The oldest revision a window starting at j holds: a range from a deleted (or missing)
    -- revision starts at the next one with content.
    local function window_from(j)
      for n = j, last do
        if revs[n] and not deleted(revs[n].action) then
          return n
        end
      end
      return last
    end

    local p = plan(k, last, first, opts.want)
    if early and (depot ~= depot0 or early.spec ~= p.spec) then
      early.call.cancel() -- the head moved, or the kept copy is stale: that annotate is no use
      early = nil
    end
    -- Annotate `p.spec`, or take the early annotate's result when it asked for the same.
    local function run(q, k2)
      if early and early.spec == q.spec then
        local e = early
        early = nil
        if e.res then
          return k2(e.res)
        end
        e.waiting = k2
        return
      end
      annotate(depot, q.spec, nil, k2)
    end

    local function full()
      run({ spec = '#' .. last }, function(ares)
        if failed(ares) then
          return cb(nil, ares.errors[1] or 'annotate failed')
        end
        set_lines(M.parse(ares.records))
        cb(tl)
      end)
    end

    if p.kind == 'none' then
      local _, i = find_kept(key)
      forget(i) -- the view owns it now
      set_lines(k.lines)
      return cb(tl)
    elseif p.kind == 'extend' then
      return run(p, function(ares)
        local _, i = find_kept(key)
        if i then
          forget(i)
        end
        local lines = not failed(ares) and M.stitch(k.lines, M.parse(ares.records), p.j)
        if not lines then
          return full()
        end
        set_lines(lines)
        cb(tl)
      end)
    elseif p.kind == 'full' then
      return full()
    end
    run(p, function(ares)
      if failed(ares) then
        return cb(nil, ares.errors[1] or 'annotate failed')
      end
      local j = window_from(p.j)
      local recent = M.parse(ares.records)
      set_lines(recent)
      tl.from = j
      cb(tl)
      local more = opts.on_more or function() end
      annotate(
        depot,
        ('#%d,#%d'):format(first, j),
        require('perforated.core.queue').PRIORITY.background,
        function(ores)
          local lines = not failed(ores) and M.stitch(M.parse(ores.records), recent, j)
          if lines then
            set_lines(lines)
            tl.from = first
            return more(tl)
          end
          -- They don't agree (or that call failed): annotate the whole history once.
          annotate(
            depot,
            '#' .. last,
            require('perforated.core.queue').PRIORITY.background,
            function(fres)
              if failed(fres) then
                return more(nil, fres.errors[1] or ores.errors[1] or 'annotate failed')
              end
              set_lines(M.parse(fres.records))
              tl.from = first
              more(tl)
            end
          )
        end
      )
    end)
  end)
  return loader
end

--- Whether revision n can be shown yet (older ones wait for the rest of the history).
---@param tl perforated.Timelapse
---@param n integer
---@return boolean
function M.loaded(tl, n)
  return n >= (tl.from or tl.first or 1)
end

-- Revision `to` is the oldest loaded one while the rest of the history is still on its way:
-- every line looks added there, so its changes aren't known yet.
local function unknown(tl, to)
  local from = tl.from
  return from and from > (tl.first or 1) and to <= from
end

--- Revision N: its lines, and each line's index.
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
    local text, los, his = tl.text, tl.lo, tl.hi
    for i = 1, #text do
      if los[i] <= n and n <= his[i] then
        k = k + 1
        lines[k] = text[i]
        idx[k] = i
      end
    end
  end
  table.insert(tl.cache, 1, { n = n, lines = lines, idx = idx })
  tl.cache[M.CACHE + 1] = nil
  return lines, idx
end

--- Lines added at N (line numbers) and lines deleted at N, grouped by the line they'd sit above
--- (key 0 = after the last line). One pass over the lines.
---@param tl perforated.Timelapse
---@param n integer
---@return integer[] added, table<integer, string[]> removed  line → texts shown above it
function M.changes(tl, n)
  local added, removed = {}, {}
  local r = tl.revs[n]
  if (r and deleted(r.action)) or unknown(tl, n) then
    return added, removed
  end
  local text, los, his, l, pending = tl.text, tl.lo, tl.hi, 0, nil
  local track_removed = n > (tl.first or 1)
  for i = 1, #text do
    local lo, hi = los[i], his[i]
    if lo <= n and n <= hi then
      l = l + 1
      if lo == n then
        added[#added + 1] = l
      end
      if pending then
        removed[l] = pending
        pending = nil
      end
    elseif track_removed and hi == n - 1 then
      pending = pending or {}
      pending[#pending + 1] = text[i]
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
  local text, los, his, l = tl.text, tl.lo, tl.hi, 0
  for i = 1, #text do
    local lo, hi = los[i], his[i]
    if lo <= b and b <= hi then
      l = l + 1
      if lo > a then
        added[#added + 1] = { l, lo }
      end
      if pending then
        removed[l] = pending
        pending = nil
      end
    elseif hi >= a and hi < b and lo <= b then
      pending = pending or {}
      pending[#pending + 1] = { text = text[i], rev = hi + 1 }
    end
  end
  if pending then
    removed[0] = pending
  end
  return added, removed
end

--- Everything a step from revision `from` to `to` needs, in one pass over the lines:
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
  local text, los, his = tl.text, tl.lo, tl.hi
  local edits, ne = {}, 0
  local pos = 0 -- line index in the buffer as the edits are applied
  local del, ins, run_start = 0, nil, -1
  local fl, tn = 0, 0 -- lines of `from` / `to` seen
  local anchor, want_next = nil, false
  local added, removed, pending = {}, {}, nil
  local known = not unknown(tl, to)
  local track_removed = known and to > (tl.first or 1)
  local prev = to - 1
  for i = 1, #text do
    local lo, hi = los[i], his[i]
    local in_from = lo <= from and from <= hi
    local in_to = lo <= to and to <= hi
    if in_to then
      tn = tn + 1
      if lo == to and known then
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
        pending[#pending + 1] = text[i]
      else
        pending = { text[i] }
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
        ins[#ins + 1] = text[i]
      else
        ins = { text[i] }
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
--- same line if it exists there, else the nearest following one, else the nearest before.
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
