--- Multi-file diff tab (diffview-style): a file panel on the left and a native diff pair.
---
--- Sources: a pending CL's opened files (depot base ↔ workspace file), a shelf (base ↔
--- shelved), a submitted CL (#rev-1 ↔ #rev), or every opened file (`:P4 diff -a`).
--- Files load lazily when selected (the next one is prefetched). Moving the cursor in the
--- panel selects; `q` closes the tab; `<Tab>`/`<S-Tab>` step through files from any window.

local p4 = require('perforated.p4')
local cls = require('perforated.changelists')
local dv = require('perforated.diff.view')

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.difftab')
local ns_current = vim.api.nvim_create_namespace('perforated.difftab.current')

---@class perforated.DiffEntry
---@field label string
---@field action string?
---@field left perforated.DiffSide
---@field right perforated.DiffSide|{ path: string }

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Right side for a workspace file: its (loaded) buffer.
local function workspace_buf(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

local open_tab

--- Open the diff tab, unless every file is identical (then just say so). Only files that
--- differ get a diff; identical ones are listed under "Identical:" at the end of the panel.
---@param ws perforated.Workspace
---@param title string
---@param entries perforated.DiffEntry[]
function M.open(ws, title, entries)
  if #entries == 0 then
    return notify(title .. ': no files')
  end
  require('perforated.same').check(ws, entries, function(same)
    local n = 0
    for i = 1, #entries do
      if same[i] then
        n = n + 1
      end
    end
    if n == #entries then
      return notify(
        #entries == 1 and (title .. ': the file is identical')
          or ('%s: all %d files are identical'):format(title, #entries)
      )
    end
    local differ, identical = {}, {}
    for i, e in ipairs(entries) do
      if same[i] then
        identical[#identical + 1] = e
      else
        differ[#differ + 1] = e
      end
    end
    open_tab(ws, title, differ, identical)
  end)
end

---@param ws perforated.Workspace
---@param title string
---@param entries perforated.DiffEntry[]
---@param identical perforated.DiffEntry[]  listed, not diffed
open_tab = function(ws, title, entries, identical)
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local panel_buf = vim.api.nvim_get_current_buf()
  vim.bo[panel_buf].buftype = 'nofile'
  vim.bo[panel_buf].bufhidden = 'wipe'
  vim.bo[panel_buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, panel_buf, 'perforated://files/' .. title)
  local panel = vim.api.nvim_get_current_win()

  -- Panel content
  local icons = require('perforated.ui.icons')
  local lines = { ' ' .. title, '' }
  for _, e in ipairs(entries) do
    local icon = icons.file(e.label)
    lines[#lines + 1] = (' %-9s %s%s'):format(
      e.action or '',
      icon ~= '' and (icon .. ' ') or '',
      e.label
    )
  end
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.bo[panel_buf].modifiable = false
  vim.api.nvim_buf_set_extmark(panel_buf, ns, 0, 0, { line_hl_group = 'PerforatedTitle' })
  for i = 1, #entries do
    vim.api.nvim_buf_set_extmark(
      panel_buf,
      ns,
      i + 1,
      1,
      { end_col = 10, hl_group = 'PerforatedAction' }
    )
  end
  if #identical > 0 then
    local first = #lines
    lines[#lines + 1] = ''
    lines[#lines + 1] = (' Identical (%d):'):format(#identical)
    for _, e in ipairs(identical) do
      lines[#lines + 1] = (' %-9s %s'):format(e.action or '', e.label)
    end
    vim.bo[panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel_buf, first, -1, false, vim.list_slice(lines, first + 1))
    vim.bo[panel_buf].modifiable = false
    vim.api.nvim_buf_set_extmark(
      panel_buf,
      ns,
      first + 1,
      0,
      { line_hl_group = 'PerforatedSection' }
    )
    for row = first + 2, #lines - 1 do
      vim.api.nvim_buf_set_extmark(panel_buf, ns, row, 0, { line_hl_group = 'PerforatedDim' })
    end
  end

  vim.cmd('rightbelow vnew')
  local rwin = vim.api.nvim_get_current_win()
  local placeholder_r = vim.api.nvim_get_current_buf()
  vim.cmd('leftabove vnew')
  local lwin = vim.api.nvim_get_current_win()
  local placeholder_l = vim.api.nvim_get_current_buf()
  for _, b in ipairs({ placeholder_l, placeholder_r }) do
    vim.bo[b].bufhidden = 'wipe'
  end
  vim.api.nvim_win_set_width(panel, math.min(50, math.floor(vim.o.columns * 0.3)))
  vim.wo[panel].winfixwidth = true
  vim.wo[panel].number = false
  vim.wo[panel].relativenumber = false
  vim.wo[panel].signcolumn = 'no'
  vim.wo[panel].cursorline = true
  vim.wo[panel].wrap = false

  local state = { current = nil }
  local owned = {} -- buffers we created (q closes the tab there)

  local function close_tab()
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
    end
  end

  local function prefetch(i)
    local e = entries[i]
    for _, side in ipairs(e and { e.left, e.right } or {}) do
      if side.spec then
        p4.print(ws, side.spec, { priority = 3 }, function() end)
      end
    end
  end

  local function side(s)
    if s.path then
      return { buf = workspace_buf(s.path) }
    end
    return s
  end

  local function show_entry(i)
    local e = entries[i]
    if not e or state.current == i then
      return
    end
    state.current = i
    for _, w in ipairs({ lwin, rwin }) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_call, w, function()
          vim.cmd('diffoff')
        end)
      end
    end
    local l, r = side(e.left), side(e.right)
    local lbuf, rbuf = dv.side_buf(ws, l), dv.side_buf(ws, r)
    for _, pair in ipairs({ { lwin, lbuf, l }, { rwin, rbuf, r } }) do
      local w, b, sd = pair[1], pair[2], pair[3]
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_set_buf(w, b)
        if not sd.buf and not owned[b] then
          owned[b] = true
          vim.keymap.set('n', 'q', close_tab, { buffer = b, nowait = true })
          vim.keymap.set('n', '<Tab>', function()
            M._step(state, 1)
          end, { buffer = b, nowait = true })
          vim.keymap.set('n', '<S-Tab>', function()
            M._step(state, -1)
          end, { buffer = b, nowait = true })
        end
      end
    end
    dv.diffthis({ lwin, rwin })
    vim.api.nvim_buf_clear_namespace(panel_buf, ns_current, 0, -1)
    vim.api.nvim_buf_set_extmark(panel_buf, ns_current, i + 1, 0, { line_hl_group = 'Visual' })
    prefetch(i + 1)
  end

  state.select = show_entry
  state.count = #entries
  state.panel = panel
  function state.step(delta)
    local n = ((state.current or 0) - 1 + delta) % #entries + 1
    if vim.api.nvim_win_is_valid(panel) then
      vim.api.nvim_win_set_cursor(panel, { n + 2, 0 })
    end
    show_entry(n)
  end

  local group = vim.api.nvim_create_augroup('perforated.difftab.' .. tab, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = panel_buf,
    -- nested: switching files must fire the usual autocmds (BufReadCmd for depot revisions,
    -- FileType, OptionSet 'diff' for user diff settings, …).
    nested = true,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(panel)[1]
      if row >= 3 then
        show_entry(row - 2)
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(panel),
    callback = function()
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
        for _, w in ipairs({ lwin, rwin }) do
          if vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_call, w, function()
              vim.cmd('diffoff')
            end)
          end
        end
        close_tab()
      end)
    end,
  })
  local function pmap(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = panel_buf, nowait = true })
  end
  pmap('q', close_tab)
  pmap('<Tab>', function()
    state.step(1)
  end)
  pmap('<S-Tab>', function()
    state.step(-1)
  end)
  pmap('<CR>', function()
    if state.current then
      vim.api.nvim_set_current_win(rwin)
    end
  end)

  -- Panel keeps its width; the two diff windows share the rest equally.
  vim.cmd('wincmd =')
  vim.api.nvim_set_current_win(panel)
  vim.api.nvim_win_set_cursor(panel, { 3, 0 })
  show_entry(1)
  vim.api.nvim_set_current_win(panel)
  return state
end

function M._step(state, delta)
  state.step(delta)
end

--- Entries for opened files (workspace file vs its base revision).
---@param recs table[] fstat records of opened files
---@param ws perforated.Workspace
---@return perforated.DiffEntry[]
local function opened_entries(ws, recs)
  local out = {}
  for _, r in ipairs(recs) do
    if r.clientFile and p4.is_text(r) then
      local base = p4.base_spec(r)
      local label = r.clientFile
      if ws.root and label:sub(1, #ws.root + 1) == ws.root .. '/' then
        label = label:sub(#ws.root + 2)
      end
      local deleted = r.action == 'delete' or r.action == 'move/delete'
      out[#out + 1] = {
        label = label,
        action = r.action,
        left = base and { spec = base } or { empty = 'new file' },
        right = deleted and { empty = 'deleted' } or { path = r.clientFile },
      }
    end
  end
  table.sort(out, function(a, b)
    return a.label < b.label
  end)
  return out
end

--- Diff tab for a changelist node item from the client view (pending, shelf or submitted).
---@param ws perforated.Workspace
---@param item table
function M.open_change(ws, item)
  if item.status == 'submitted' or (item.rec == nil and item.files == nil and item.desc) then
    -- Submitted CL: #rev-1 ↔ #rev for every file.
    return cls.describe(ws, { item.change }, {}, function(by)
      local d = by[item.change]
      if not d then
        return notify('could not describe CL ' .. item.change, vim.log.levels.ERROR)
      end
      local entries = {}
      for _, f in ipairs(d.files) do
        local rev = tonumber(f.rev) or 1
        local added = f.action == 'add'
          or f.action == 'branch'
          or f.action == 'move/add'
          or rev <= 1
        local deleted = f.action == 'delete' or f.action == 'move/delete'
        entries[#entries + 1] = {
          label = f.depotFile,
          action = f.action,
          left = added and { empty = 'added' } or { spec = f.depotFile .. '#' .. (rev - 1) },
          right = deleted and { empty = 'deleted' } or { spec = f.depotFile .. '#' .. rev },
        }
      end
      M.open(ws, 'CL ' .. item.change, entries)
    end)
  end
  if item.files and #item.files > 0 then
    return M.open(
      ws,
      item.change == 'default' and 'default' or ('CL ' .. item.change),
      opened_entries(ws, item.files)
    )
  end
  local shelved = item.shelved
  if not shelved then
    -- A shelf node: fetch its files.
    return cls.shelved_files(ws, { item.change }, function(by)
      M.open_change(ws, { change = item.change, shelved = by[item.change] or {}, files = {} })
    end)
  end
  local entries = {}
  for _, f in ipairs(shelved) do
    local base = f.rev and tonumber(f.rev) and tonumber(f.rev) > 0 and (f.depotFile .. '#' .. f.rev)
    entries[#entries + 1] = {
      label = f.depotFile,
      action = f.action,
      left = base and { spec = base } or { empty = 'new file' },
      right = f.action == 'delete' and { empty = 'deleted' }
        or { spec = f.depotFile .. '@=' .. item.change },
    }
  end
  M.open(ws, ('CL %s (shelved)'):format(item.change), entries)
end

--- A shelf against the workspace: every shelved file (right) next to its workspace file (left).
--- Files that aren't in the workspace (unmapped or not synced) show an empty side.
---@param ws perforated.Workspace
---@param change string
---@param shelved table[]?  the shelf's files (fetched when nil)
function M.open_shelf_vs_workspace(ws, change, shelved)
  if not shelved then
    return cls.shelved_files(ws, { change }, function(by)
      M.open_shelf_vs_workspace(ws, change, by[change] or {})
    end)
  end
  local depot = vim.tbl_map(function(f)
    return f.depotFile
  end, shelved)
  require('perforated.revs').where(ws, depot, function(map)
    local entries = {}
    for _, f in ipairs(shelved) do
      local path = map[f.depotFile]
      local label = path or f.depotFile
      if path and ws.root and label:sub(1, #ws.root + 1) == ws.root .. '/' then
        label = label:sub(#ws.root + 2)
      end
      entries[#entries + 1] = {
        label = label,
        action = f.action,
        left = (path and vim.uv.fs_stat(path)) and { path = path }
          or { empty = 'not in workspace' },
        right = (f.action == 'delete' or f.action == 'move/delete') and { empty = 'deleted' }
          or { spec = f.depotFile .. '@=' .. change },
      }
    end
    table.sort(entries, function(a, b)
      return a.label < b.label
    end)
    M.open(ws, ('CL %s (shelved vs workspace)'):format(change), entries)
  end)
end

--- Every opened file of the workspace.
---@param ws perforated.Workspace
function M.open_opened(ws)
  p4.fstat_opened(ws, {}, function(recs)
    M.open(ws, 'opened files · ' .. (ws:client() or ws.key), opened_entries(ws, recs or {}))
  end)
end

return M
