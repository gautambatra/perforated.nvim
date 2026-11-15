--- What the poll's news says changed (loaded with the first news): the files whose opened
--- records differ, or the changelists whose shelf came or went, so a visible client view and
--- the lists refresh only those. News it can't attribute names nothing (everything refreshes).

local M = {}

---@param ws perforated.Workspace
---@param data table
local function emit(ws, data)
  require('perforated.core.events').emit(
    'Changed',
    vim.tbl_extend('force', { ws = ws.key, source = 'poll' }, data)
  )
end

--- The opened files' records differ from the last refresh: name the files.
---@param ws perforated.Workspace
---@param before table<string, string>  depot path → signature (last refresh)
---@param now table<string, string>
---@param old table<string, table>?  depot path → opened record (last refresh)
---@param new table<string, table>
function M.opened(ws, before, now, old, new)
  local files, submitted = {}, false
  local function add(depot, rec)
    files[#files + 1] = rec and rec.clientFile or depot
  end
  for depot, sig in pairs(now) do
    if before[depot] ~= sig then
      local o, n = old and old[depot], new[depot]
      add(depot, n)
      -- A newer submitted revision: one of them may be the user's (Recent submitted).
      submitted = submitted or (o ~= nil and o.headRev ~= n.headRev)
    end
  end
  for depot in pairs(before) do
    if not now[depot] then
      add(depot, old and old[depot])
      submitted = true -- (reverted, or submitted)
    end
  end
  if #files == 0 then
    return
  end
  table.sort(files)
  if #files > require('perforated.checkout').CHANGED_FILES_MAX then
    return emit(ws, {})
  end
  emit(ws, { files = files, submitted = submitted or nil })
end

--- This client's pending changelists differ from the last probe: name those whose shelf came
--- or went (their shelved files are asked again); one that's gone may have been submitted.
---@param ws perforated.Workspace
---@param before table<string, { sig: string, shelved: boolean }>  change → (last probe)
---@param now table<string, { sig: string, shelved: boolean }>
function M.pending(ws, before, now)
  local shelves, gone = {}, false
  for c, n in pairs(now) do
    local o = before[c]
    if n.shelved ~= (o ~= nil and o.shelved) then
      shelves[#shelves + 1] = c
    end
  end
  for c in pairs(before) do
    if not now[c] then
      gone = true
      if before[c].shelved then
        shelves[#shelves + 1] = c -- (its shelf drops out)
      end
    end
  end
  table.sort(shelves)
  emit(ws, { changes = shelves, submitted = gone or nil, no_files = true })
end

return M
