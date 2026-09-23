--- Picker sources: `:P4 pick {pending|opened|submitted|users}`.

local p4 = require('perforated.p4')
local picker = require('perforated.picker')

local M = {}

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

local function date(t)
  t = tonumber(t)
  return t and os.date('%Y-%m-%d', t) or ''
end

local function desc_lines(c)
  local out = {
    ('CL %s · %s · %s · %s'):format(c.change, c.user or '?', c.client or '?', date(c.time)),
    '',
  }
  vim.list_extend(out, vim.split(c.desc or '', '\n', { plain = true }))
  return out
end

--- Pending changelists → diff tab of the chosen CL's files.
function M.pending(ws)
  p4.pending_changes(ws, function(changes, err)
    if not changes then
      return vim.notify('[perforated] ' .. tostring(err), vim.log.levels.ERROR)
    end
    p4.fstat_opened(ws, {}, function(recs)
      local files = {}
      for _, r in ipairs(recs or {}) do
        local cl = r.change or 'default'
        files[cl] = files[cl] or {}
        table.insert(files[cl], r)
      end
      local items = { { change = 'default', desc = '', files = files.default or {} } }
      for _, c in ipairs(changes) do
        c.files = files[c.change] or {}
        items[#items + 1] = c
      end
      picker.pick({
        title = 'Pending changelists',
        items = items,
        format = function(c)
          if c.change == 'default' then
            return ('default  (%d files)'):format(#c.files)
          end
          return ('%-8s %s  (%d files)'):format(c.change, first_line(c.desc), #c.files)
        end,
        preview = function(c)
          local out = c.change == 'default' and { 'default changelist', '' } or desc_lines(c)
          out[#out + 1] = ''
          for _, f in ipairs(c.files) do
            out[#out + 1] = ('%-10s %s'):format(f.action or '', f.depotFile)
          end
          return out
        end,
        on_choice = function(chosen)
          if chosen then
            require('perforated.diff.tab').open_change(ws, chosen[1])
          end
        end,
      })
    end)
  end)
end

--- Opened files → open them.
function M.opened(ws)
  p4.fstat_opened(ws, {}, function(recs)
    recs = recs or {}
    picker.pick({
      title = 'Opened files',
      items = recs,
      multi = true,
      format = function(r)
        local path = r.clientFile or r.depotFile
        if ws.root and path:sub(1, #ws.root + 1) == ws.root .. '/' then
          path = path:sub(#ws.root + 2)
        end
        return ('%-10s %s  %s'):format(
          r.action or '',
          path,
          r.change == 'default' and '' or ('CL ' .. r.change)
        )
      end,
      on_choice = function(chosen)
        for _, r in ipairs(chosen or {}) do
          if r.clientFile then
            vim.cmd('edit ' .. vim.fn.fnameescape(r.clientFile))
          end
        end
      end,
    })
  end)
end

--- Submitted changelists (client view; `user` filter) → diff tab.
---@param ws perforated.Workspace
---@param opts { user: string?, path: string? }?
function M.submitted(ws, opts)
  opts = opts or {}
  p4.submitted_changes(ws, { user = opts.user, path = opts.path, max = 200 }, function(changes, err)
    if not changes then
      return vim.notify('[perforated] ' .. tostring(err), vim.log.levels.ERROR)
    end
    picker.pick({
      title = 'Submitted changelists' .. (opts.user and (' · ' .. opts.user) or ''),
      items = changes,
      format = function(c)
        return ('%-8s %s %-12s %s'):format(c.change, date(c.time), c.user or '', first_line(c.desc))
      end,
      preview = desc_lines,
      on_choice = function(chosen)
        if chosen then
          require('perforated.diff.tab').open_change(ws, chosen[1])
        end
      end,
    })
  end)
end

--- Users → their submitted changelists.
function M.users(ws)
  ws:run({ 'users' }, {}, function(res)
    picker.pick({
      title = 'Users',
      items = res.records,
      format = function(u)
        return ('%-16s %s  <%s>'):format(u.User or '', u.FullName or '', u.Email or '')
      end,
      on_choice = function(chosen)
        if chosen then
          require('perforated.views.changes').open(ws, { user = chosen[1].User })
        end
      end,
    })
  end)
end

return M
