--- "View changelist" popup (`K`): header, full description and files — opened files for
--- pending changelists, shelved files, or the submitted files. Scrollable; `q`/`<Esc>` close,
--- `D` opens the diff tab for the changelist, `C` switches the popup to edit mode (the
--- description editor in the same float; saving or cancelling comes back to the popup).

local cls = require('perforated.changelists')

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.change_info')

local function date(t)
  t = tonumber(t)
  return t and os.date('%Y-%m-%d %H:%M', t) or ''
end

--- What the popup shows: the changelist (`describe -s`) and, for a pending one, its shelf.
---@param ws perforated.Workspace
---@param item table  client-view change item { change, rec?, files?, shelved? } or a `p4 changes` record
---@param cb fun(d: { rec: table, files: table[] }?, shelved: table[]?)  nil: couldn't describe
function M.fetch(ws, item, cb)
  local change = item.change
  if change == 'default' then
    local function done(files)
      cb({
        rec = { change = 'default', status = 'pending', user = ws:user(), client = ws:client() },
        files = files,
      }, {})
    end
    if item.files then
      return done(item.files)
    end
    -- e.g. a changelist chooser's "default" entry: its opened files.
    return require('perforated.p4').fstat_opened(ws, { priority = 3 }, function(recs)
      done(vim.tbl_filter(function(r)
        return r.change == 'default'
      end, recs or {}))
    end)
  end
  -- A client-view item carries its shelved files; a `p4 changes` record only a "shelved" flag.
  local shelved = type(item.shelved) == 'table' and item.shelved or nil
  cls.describe(ws, { change }, {}, function(by)
    local d = by[change]
    if not d then
      return cb(nil)
    end
    if not shelved and d.rec.status == 'pending' then
      return cls.shelved_files(ws, { change }, function(sh)
        cb(d, sh[change] or {})
      end)
    end
    cb(d, shelved or {})
  end)
end

---@param ws perforated.Workspace
---@param item table  client-view change item { change, rec?, files?, shelved? } or a `p4 changes` record
function M.open(ws, item)
  M.fetch(ws, item, function(d, shelved)
    if not d then
      return require('perforated.ui.toast').notify(
        '[perforated] could not describe CL ' .. item.change,
        vim.log.levels.ERROR
      )
    end
    M.show(ws, item, d, shelved)
  end)
end

--- The popup's lines and their highlights (row → group), for the popup and picker previews.
---@param item table
---@param d { rec: table, files: table[] }
---@param shelved table[]
---@return string[] lines, table<integer, string> hls, string title
function M.render(item, d, shelved)
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
  return lines, hls, title
end

---@param buf integer
---@param lines string[]
---@param hls table<integer, string>
local function fill(buf, lines, hls)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = hl })
  end
end

--- A picker's changelist preview: the popup's content in the picker's preview buffer. Filled
--- once fetched (each changelist once per picker); a buffer moved on to another entry by then
--- is left alone.
---@param ws perforated.Workspace
---@return fun(item: table, buf: integer)
function M.previewer(ws)
  require('perforated.hl').setup()
  local cache = {} ---@type table<string, { lines: string[], hls: table<integer, string> }>
  return function(item, buf)
    local change = item and item.change
    if not change or change == 'new' then
      return fill(buf, {}, {})
    end
    vim.b[buf].perforated_cl_preview = change
    if cache[change] then
      return fill(buf, cache[change].lines, cache[change].hls)
    end
    fill(
      buf,
      { change == 'default' and 'default changelist…' or ('CL %s…'):format(change) },
      {}
    )
    M.fetch(ws, item, function(d, shelved)
      local lines, hls = { 'could not describe CL ' .. change }, {}
      if d then
        lines, hls = M.render(item, d, shelved)
        cache[change] = { lines = lines, hls = hls }
      end
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].perforated_cl_preview == change then
        fill(buf, lines, hls)
      end
    end)
  end
end

---@param ws perforated.Workspace
---@param item table
---@param d { rec: table, files: table[] }
---@param shelved table[]
function M.show(ws, item, d, shelved)
  local rec = d.rec
  local lines, hls, title = M.render(item, d, shelved)

  -- Your own changelists (or anyone's with change.allow_force); never the default one.
  local editable = rec.change ~= 'default'
    and (rec.user == ws:user() or require('perforated.config').get().change.allow_force)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  fill(buf, lines, hls)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'perforated-changelist'
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
    footer = ' q close · <CR> describe · D diff all files'
      .. ((#shelved > 0 and ws.mode ~= 'connection') and ' · S unshelve' or '')
      .. (editable and ' · C edit ' or ' '),
    footer_pos = 'right',
  })
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  vim.wo[win][0].wrap = true
  vim.wo[win][0].cursorline = true
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, lhs in ipairs({ 'q', '<Esc>', 'K' }) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true })
  end
  vim.keymap.set('n', '<CR>', function()
    close()
    require('perforated.views.describe').open(ws, rec.change)
  end, { buffer = buf, nowait = true })
  require('perforated.lookup').map(buf, function()
    close()
    return ws
  end)
  vim.keymap.set('n', 'D', function()
    close()
    require('perforated.diff.tab').open_change(ws, item)
  end, { buffer = buf, nowait = true })
  if #shelved > 0 and ws.mode ~= 'connection' then
    -- Unshelve the whole shelf, anyone's: into this changelist if it's yours here, else one
    -- you pick.
    vim.keymap.set('n', 'S', function()
      close()
      require('perforated.ops').unshelve(ws, rec.change, nil, nil)
    end, { buffer = buf, nowait = true })
  end
  if editable then
    vim.keymap.set('n', 'C', function()
      require('perforated.views.change_editor').edit(ws, rec.change, {
        submitted = rec.status == 'submitted',
        win = win,
        on_done = function(_, how)
          -- Back to the popup (re-read, so a saved description shows), unless the cursor
          -- simply left the editor.
          if how ~= 'leave' then
            M.open(ws, item)
          end
        end,
      })
    end, { buffer = buf, nowait = true })
  end
  return buf, win
end

return M
