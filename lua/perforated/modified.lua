--- Which opened files actually differ from their base (P4V's blue vs white file icons).
---
--- One `p4 diff -sa` call: p4 compares each opened file with its base on the client side and
--- lists the ones that differ. Files open in Neovim with unsaved edits use the buffer's own
--- diff state instead. Adds, deletes, moves and branches always count as changed.

local p4 = require('perforated.p4')

local M = {}

local ALWAYS = {
  add = true,
  delete = true,
  ['move/add'] = true,
  ['move/delete'] = true,
  branch = true,
  import = true,
  purge = true,
}

--- Opened files (of this client) that differ from their base, as a set of path keys.
---@param ws perforated.Workspace
---@param paths string[]?  limit to these files (nil = every opened file)
---@param cb fun(set: table<string, true>?)  nil when the query failed
function M.query(ws, paths, cb)
  -- Escaped, or p4 reads `icon@2x.png` as a revision and the whole batch fails.
  -- No timeout: p4 reads every file it's asked about, so the time grows with their size (a
  -- large changelist on a slow disk takes longer than any fixed limit).
  local opts = paths
      and { globals = { '-x', '-' }, stdin = p4.escape_all(paths), priority = 2, timeout = 0 }
    or { priority = 2, timeout = 0 }
  if paths and #paths == 0 then
    return vim.schedule(function()
      cb({})
    end)
  end
  ws:run({ 'diff', '-sa' }, opts, function(res)
    -- A cut-off answer lists only some of the changed files: the others are unknown, not
    -- unchanged.
    if require('perforated.core.runner').cut(res) or (not res.ok and #res.records == 0) then
      return cb(nil)
    end
    local set = {}
    for _, r in ipairs(res.records) do
      if r.clientFile then
        set[p4.key(ws, r.clientFile)] = true
      end
    end
    cb(set)
  end)
end

--- Local stats of `paths` (local paths), all at once: key → `mtime(ns):size`, false when the
--- file is missing. A marker answered after these were taken holds while they still match:
--- a file whose stats didn't change needn't be asked again (`valid`).
---@param ws perforated.Workspace
---@param paths string[]
---@param cb fun(stats: table<string, string|false>)
function M.stats(ws, paths, cb)
  local out, left = {}, #paths
  if left == 0 then
    return vim.schedule(function()
      cb(out)
    end)
  end
  for _, p in ipairs(paths) do
    local k = p4.key(ws, p)
    vim.uv.fs_stat(p, function(_, st)
      out[k] = st and ('%d.%09d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size) or false
      left = left - 1
      if left == 0 then
        vim.schedule(function()
          cb(out)
        end)
      end
    end)
  end
end

--- `query`, with the files' stats taken before it asked (`stats`) and when it asked (`t0`,
--- seconds since the epoch: `remember` judges files with no stats by it).
---@param ws perforated.Workspace
---@param paths string[]?  nil = every opened file (stats of those `ws.opened` knows)
---@param cb fun(set: table<string, true>?, stats: table<string, string|false>, t0: number)
function M.query_stat(ws, paths, cb)
  local files = paths
      and vim.tbl_filter(function(p)
        return p:sub(1, 2) ~= '//' -- (a depot path: no local file to stat)
      end, paths)
    or M.opened_paths(ws)
  M.stats(ws, files, function(stats)
    local t0 = os.time()
    M.query(ws, paths, function(set)
      cb(set, stats, t0)
    end)
  end)
end

--- A file with no stats from before its query (not known to be opened then) is remembered
--- only when it was last modified this long before the query: it can't have changed while
--- p4 compared it (and a little clock skew between the disk and here doesn't matter).
M.SETTLED_S = 2

--- This client's opened files as local paths.
---@param ws perforated.Workspace
---@return string[]
function M.opened_paths(ws)
  local out = {}
  for _, r in pairs(ws.opened or {}) do
    if r.clientFile then
      out[#out + 1] = r.clientFile
    end
  end
  table.sort(out)
  return out
end

-- The marker cache (`ws.markers`): key → { changed, stat, base }. An answer holds while the
-- file's local stats (taken before p4 compared it) and its base revision are unchanged: an
-- edit anywhere moves the stats, a sync or resolve the base. `<F5>` / `:P4 refresh` ask anew.

--- This client's opened records with a local file (those a marker applies to).
---@param ws perforated.Workspace
---@param recs table[]
---@return table[]
local function own(ws, recs)
  local client = ws:client()
  return vim.tbl_filter(function(r)
    return r.clientFile ~= nil and r.action ~= nil and (r.client == nil or r.client == client)
  end, recs)
end

--- Remember one answer.
---@param ws perforated.Workspace
---@param rec table  its opened record (the base it was compared with)
---@param changed boolean
---@param stat string|false  its stats taken before p4 compared it
function M.store(ws, rec, changed, stat)
  ws.markers = ws.markers or {}
  ws.markers[p4.key(ws, rec.clientFile)] =
    { changed = changed, stat = stat, base = p4.base_spec(rec) or '' }
end

--- The cached answers of `recs` that still hold (same stats, same base): key → changed; and
--- every file's stats now (the baseline for answers asked after).
---@param ws perforated.Workspace
---@param recs table[]  opened records
---@param cb fun(valid: table<string, boolean>, stats: table<string, string|false>)
function M.valid(ws, recs, cb)
  recs = own(ws, recs)
  M.stats(
    ws,
    vim.tbl_map(function(r)
      return r.clientFile
    end, recs),
    function(stats)
      local out, cache = {}, ws.markers or {}
      for _, r in ipairs(recs) do
        local k = p4.key(ws, r.clientFile)
        local e = cache[k]
        if e and stats[k] ~= nil and e.stat == stats[k] and e.base == (p4.base_spec(r) or '') then
          out[k] = e.changed
        end
      end
      cb(out, stats)
    end
  )
end

--- Markers of these opened records, as `query`'s set: cached answers that still hold, one
--- `diff -sa` for the rest (none when nothing moved). `opts.fresh`: ask every one;
--- `opts.all`: `recs` are every opened file (entries of other files are dropped).
---@param ws perforated.Workspace
---@param recs table[]
---@param opts { fresh: boolean?, all: boolean? }?
---@param cb fun(set: table<string, true>?)  nil when the query failed
function M.markers(ws, recs, opts, cb)
  opts = opts or {}
  recs = own(ws, recs)
  if opts.all then
    M.prune(ws, recs)
  end
  M.valid(ws, recs, function(valid, stats)
    if opts.fresh then
      valid = {}
    end
    local need, paths = {}, {}
    for _, r in ipairs(recs) do
      if valid[p4.key(ws, r.clientFile)] == nil then
        need[#need + 1], paths[#paths + 1] = r, r.clientFile
      end
    end
    local out = {}
    for k, c in pairs(valid) do
      out[k] = c or nil
    end
    if #need == 0 then
      return cb(out)
    end
    require('perforated.core.debug').debug(
      'modified',
      '%s: %d of %d marker(s) asked, the rest cached',
      ws.key,
      #need,
      #recs
    )
    M.query(ws, paths, function(set)
      if not set then
        return cb(nil)
      end
      for _, r in ipairs(need) do
        local k = p4.key(ws, r.clientFile)
        M.store(ws, r, set[k] == true, stats[k])
        out[k] = set[k]
      end
      cb(out)
    end)
  end)
end

--- Remember the answers of a query its caller ran itself (`query_stat`), once the opened
--- records are known: those of `paths` (local or depot paths; nil = every one).
---@param ws perforated.Workspace
---@param recs table[]  opened records
---@param set table<string, true>
---@param stats table<string, string|false>  from `query_stat`
---@param paths string[]?
---@param t0 number?  from `query_stat`: files without stats are judged by their mtime
function M.remember(ws, recs, set, stats, paths, t0)
  local asked
  if paths then
    asked = {}
    for _, f in ipairs(paths) do
      asked[f:sub(1, 2) == '//' and f or p4.key(ws, f)] = true
    end
  end
  local later = {}
  for _, r in ipairs(own(ws, recs)) do
    local k = p4.key(ws, r.clientFile)
    if not asked or asked[k] or asked[r.depotFile] then
      if stats[k] ~= nil then
        M.store(ws, r, set[k] == true, stats[k])
      elseif t0 then
        later[#later + 1] = r
      end
    end
  end
  for _, r in ipairs(later) do
    vim.uv.fs_stat(r.clientFile, function(_, st)
      if st and st.mtime.sec < t0 - M.SETTLED_S then
        local stat = ('%d.%09d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
        vim.schedule(function()
          M.store(ws, r, set[p4.key(ws, r.clientFile)] == true, stat)
        end)
      end
    end)
  end
end

--- Drop the entries of files not among `recs` (no longer opened).
---@param ws perforated.Workspace
---@param recs table[]  every opened record
function M.prune(ws, recs)
  if not ws.markers then
    return
  end
  local keep = {}
  for _, r in ipairs(recs) do
    if r.clientFile then
      keep[p4.key(ws, r.clientFile)] = true
    end
  end
  for k in pairs(ws.markers) do
    if not keep[k] then
      ws.markers[k] = nil
    end
  end
end

--- Changed/unchanged for files open in Neovim with unsaved edits (their buffer's diff state),
--- keyed like M.query's set. Compute once per render.
---@param ws perforated.Workspace
---@return table<string, boolean>
function M.overlay(ws)
  local out = {}
  for buf, st in pairs(require('perforated.buffer').all()) do
    if st.ws == ws and st.base and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      out[st.key] = #st.hunks > 0
    end
  end
  return out
end

--- Is this opened file changed? nil when it doesn't apply (not opened here, or unknown).
---@param ws perforated.Workspace
---@param rec table  fstat/opened record
---@param set table<string, true>?  from M.query
---@param overlay table<string, boolean>?  from M.overlay
---@return boolean?
function M.is_changed(ws, rec, set, overlay)
  if not rec.action or not rec.change or not rec.clientFile then
    return nil
  end
  if rec.client and rec.client ~= ws:client() then
    return nil
  end
  if ALWAYS[rec.action] then
    return true
  end
  local key = p4.key(ws, rec.clientFile)
  -- Unsaved edits: the buffer's diff against its base knows better than the disk.
  if overlay and overlay[key] ~= nil then
    return overlay[key]
  end
  if not set then
    return nil
  end
  return set[key] == true
end

--- Text chunks for the marker: `● ` (changed) / `  ` (unchanged) and the highlight to use for
--- the rest of the row (nil = the row's normal colours).
---@param changed boolean?
---@return { [1]: string, [2]: string? }? marker, string? row_hl
function M.marker(changed)
  if changed == nil then
    return nil, nil
  end
  if changed then
    return { require('perforated.ui.icons').glyph('modified') .. ' ', 'PerforatedModified' },
      'PerforatedModified'
  end
  return { '  ' }, 'PerforatedUnchanged'
end

return M
