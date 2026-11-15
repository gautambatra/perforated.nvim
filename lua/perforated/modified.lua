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
  local opts = paths and { globals = { '-x', '-' }, stdin = p4.escape_all(paths), priority = 2 }
    or { priority = 2 }
  if paths and #paths == 0 then
    return vim.schedule(function()
      cb({})
    end)
  end
  ws:run({ 'diff', '-sa' }, opts, function(res)
    if not res.ok and #res.records == 0 and #res.errors > 0 then
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
--- a file whose stats didn't change needn't be asked again (`touched`).
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

--- `query`, with the files' stats taken before it asked (`stats`).
---@param ws perforated.Workspace
---@param paths string[]?  nil = every opened file (stats of those `ws.opened` knows)
---@param cb fun(set: table<string, true>?, stats: table<string, string|false>)
function M.query_stat(ws, paths, cb)
  local files = paths
      and vim.tbl_filter(function(p)
        return p:sub(1, 2) ~= '//' -- (a depot path: no local file to stat)
      end, paths)
    or M.opened_paths(ws)
  M.stats(ws, files, function(stats)
    M.query(ws, paths, function(set)
      cb(set, stats)
    end)
  end)
end

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

--- The opened files whose local stats differ from `baseline` (or have none): edited since
--- their marker was answered, inside Neovim or out. Their stats now, for the next baseline.
---@param ws perforated.Workspace
---@param baseline table<string, string|false>
---@param cb fun(paths: string[], stats: table<string, string|false>)
function M.touched(ws, baseline, cb)
  local paths = M.opened_paths(ws)
  M.stats(ws, paths, function(stats)
    local out = vim.tbl_filter(function(p)
      local k = p4.key(ws, p)
      return baseline[k] == nil or baseline[k] ~= stats[k]
    end, paths)
    cb(out, stats)
  end)
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
