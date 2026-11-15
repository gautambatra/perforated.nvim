--- The toast for opened files that became stale (or are unresolved, at startup), with who
--- submitted the newer revision. Loaded the first time there's one to show.

local M = {}

--- Fill in user/description for changes we don't know yet (one describe call).
---@param ws perforated.Workspace
---@param changes string[]
---@param cb fun()
local function learn_changes(ws, changes, cb)
  local need = {}
  for _, c in ipairs(changes) do
    if not ws.clmemo[c] then
      need[#need + 1] = c
    end
  end
  if #need == 0 then
    return cb()
  end
  ws:run(vim.list_extend({ 'describe', '-s' }, need), { priority = 3 }, function(res)
    for _, r in ipairs(res.records) do
      if r.change then
        ws.clmemo[r.change] = { user = r.user, client = r.client, time = r.time, desc = r.desc }
      end
    end
    cb()
  end)
end

---@param ws perforated.Workspace
---@param recs table[]
---@param initial boolean
function M.show(ws, recs, initial)
  local icons = require('perforated.ui.icons')
  local changes = {}
  for _, r in ipairs(recs) do
    if r.headChange then
      changes[#changes + 1] = r.headChange
    end
  end
  learn_changes(ws, changes, function()
    local lines = {}
    local nstale, nunres = 0, 0
    for _, r in ipairs(recs) do
      local name = vim.fn.fnamemodify(r.clientFile or r.depotFile, ':~:.')
      if require('perforated.status').is_stale(r) then
        nstale = nstale + 1
        local m = ws.clmemo[r.headChange or ''] or {}
        lines[#lines + 1] = ('%s %s  #%s→#%s · CL %s%s'):format(
          icons.glyph('stale'),
          name,
          r.haveRev,
          r.headRev,
          r.headChange or '?',
          m.user and (' · ' .. m.user) or ''
        )
      end
      if r.unresolved then
        nunres = nunres + 1
        lines[#lines + 1] = ('%s %s  unresolved'):format(icons.glyph('unresolved'), name)
      end
    end
    if #lines == 0 then
      return
    end
    lines[#lines + 1] = 'sync before submitting · :P4 status for details'
    local title
    if initial then
      title = ('Perforce: %d stale, %d unresolved opened file(s)'):format(nstale, nunres)
    else
      title = ('Perforce: %d opened file(s) now stale'):format(nstale)
    end
    require('perforated.ui.toast').show(
      title,
      lines,
      vim.log.levels.WARN,
      { detail = true, place = 'background' }
    )
  end)
end

return M
