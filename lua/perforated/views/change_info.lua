--- "View changelist" popup (`K`): header, full description and files — opened files for
--- pending changelists, shelved files, or the submitted files. Scrollable; `q`/`<Esc>` close,
--- `D` opens the diff tab for the changelist.

local cls = require('perforated.changelists')

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.change_info')

local function date(t)
  t = tonumber(t)
  return t and os.date('%Y-%m-%d %H:%M', t) or ''
end

---@param ws perforated.Workspace
---@param item table  client-view change item { change, rec?, files?, shelved? } or a `p4 changes` record
function M.open(ws, item)
  local change = item.change
  if change == 'default' then
    return M.show(ws, item, {
      rec = { change = 'default', status = 'pending', user = ws:user(), client = ws:client() },
      files = item.files or {},
    }, item.shelved or {})
  end
  cls.describe(ws, { change }, {}, function(by)
    local d = by[change]
    if not d then
      return vim.notify('[perforated] could not describe CL ' .. change, vim.log.levels.ERROR)
    end
    if item.shelved == nil and d.rec.status == 'pending' then
      return cls.shelved_files(ws, { change }, function(sh)
        M.show(ws, item, d, sh[change] or {})
      end)
    end
    M.show(ws, item, d, item.shelved or {})
  end)
end

---@param ws perforated.Workspace
---@param item table
---@param d { rec: table, files: table[] }
---@param shelved table[]
function M.show(ws, item, d, shelved)
  local rec = d.rec
  local lines, hls = {}, {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      hls[#lines] = hl
    end
  end
  local title = rec.change == 'default' and 'default changelist' or ('CL ' .. rec.change)
  add(
    ('%s · %s · %s@%s · %s'):format(
      title,
      rec.status or '?',
      rec.user or '?',
      rec.client or '?',
      date(rec.time)
    ),
    'PerforatedTitle'
  )
  add('')
  if rec.desc and rec.desc ~= '' then
    for _, l in ipairs(vim.split(vim.trim(rec.desc), '\n', { plain = true })) do
      add('  ' .. l)
    end
    add('')
  end
  -- Opened files (fstat records, from the client view) are fresher than `describe -s`.
  local files = item.files or d.files
  add(('Files (%d)'):format(#(files or {})), 'PerforatedSection')
  for _, f in ipairs(files or {}) do
    add(
      ('  %-10s %s#%s'):format(
        f.action or '',
        f.depotFile or f.clientFile or '?',
        f.rev or f.haveRev or '?'
      ),
      nil
    )
  end
  if #shelved > 0 then
    add('')
    add(('Shelved (%d)'):format(#shelved), 'PerforatedShelved')
    for _, f in ipairs(shelved) do
      add(
        ('  %-10s %s#%s'):format(f.action or '', f.depotFile, f.rev or '?'),
        'PerforatedShelvedFile'
      )
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'perforated-changelist'
  for row, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = hl })
  end
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.7))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'left',
    footer = ' q close · D diff all files ',
    footer_pos = 'right',
  })
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, lhs in ipairs({ 'q', '<Esc>', 'K' }) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true })
  end
  vim.keymap.set('n', 'D', function()
    close()
    require('perforated.diff.tab').open_change(ws, item)
  end, { buffer = buf, nowait = true })
  return buf, win
end

return M
