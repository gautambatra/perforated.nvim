--- Multi-file diff tab (diffview-style): a file panel on the left and a native diff pair.
---
--- Sources: a pending CL's opened files (depot base ↔ workspace file), a shelf (base ↔
--- shelved), a submitted CL (#rev-1 ↔ #rev), or every opened file (`:P4 diff -a`).
--- Files load lazily when selected (the next one is prefetched). Moving the cursor in the
--- panel selects; `q` closes the tab; `<Tab>`/`<S-Tab>` step through files from any window.
--- The panel's keys come from the action registry (`ui/keys.lua`): `?`, the `.` menu and the
--- footer, `o` opens the file and `r` reverts an opened one.

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
---@field client_file string?  set for opened files: what `r` reverts

-- "Opening diff view…": shown as soon as a diff tab is asked for (fetching file lists and the
-- identical-files check take a moment), closed when the tab opens or the request ends any
-- other way (every such way goes through `notify` or `finish_busy`).
local busy ---@type fun()?

local function start_busy()
  if busy then
    return
  end
  local close = require('perforated.ui.toast').busy('Opening diff view…')
  busy = close
  -- Never left up by an unexpected failure.
  vim.defer_fn(function()
    if busy == close then
      busy = nil
      close()
    end
  end, 30000)
end

local function finish_busy()
  if busy then
    local close = busy
    busy = nil
    close()
  end
end

local function notify(msg, level)
  finish_busy()
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Right side for a workspace file: its (loaded) buffer.
local function workspace_buf(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

local open_tab

--- A panel line: action, icon, then the name before its folder, so a long path cuts off the
--- folder and not the name. Returns the line and the byte column where the folder starts.
---@param e perforated.DiffEntry
---@param icon boolean
---@return string line, integer? dir_col
local function panel_line(e, icon)
  local dir, name = e.label:match('^(.*/)([^/]+)$')
  name = name or e.label
  local ic = icon and require('perforated.ui.icons').file(e.label) or ''
  local line = (' %-9s %s%s'):format(e.action or '', ic ~= '' and (ic .. ' ') or '', name)
  if not dir then
    return line, nil
  end
  return line .. '  ' .. dir, #line + 2
end

--- The panel's actions. `p` is the open tab: { ws, step, focus, close, open, revert, actions,
--- view }.
---@param p table
---@return perforated.Action[]
local function panel_actions(p)
  local FILE = { file = true }
  return {
    require('perforated.lookup').action(function()
      return p.ws
    end),
    {
      id = 'next_file',
      desc = 'Next file',
      keys = { 'j', '<Down>', '<Tab>' },
      nomenu = true,
      run = function()
        p.step(vim.v.count1)
      end,
    },
    {
      id = 'prev_file',
      desc = 'Previous file',
      keys = { 'k', '<Up>', '<S-Tab>' },
      nomenu = true,
      run = function()
        p.step(-vim.v.count1)
      end,
    },
    {
      id = 'focus_diff',
      desc = 'Go to the diff',
      keys = { '<CR>' },
      kinds = FILE,
      nomenu = true,
      run = function()
        p.focus()
      end,
    },
    {
      id = 'open',
      desc = 'Open file',
      keys = { 'o' },
      kinds = FILE,
      footer = 10,
      run = function(items)
        p.open(items[1])
      end,
    },
    {
      id = 'revert',
      desc = 'Revert',
      keys = { 'r' },
      p4v = { '<C-r>' },
      kinds = FILE,
      footer = 20,
      when = function(e)
        return e ~= nil and e.client_file ~= nil
      end,
      run = function(items)
        p.revert(items[1])
      end,
    },
    {
      id = 'close',
      desc = 'Close',
      keys = { 'q' },
      p4v = { '<C-w>' },
      nomenu = true,
      run = function()
        p.close()
      end,
    },
    {
      id = 'help',
      desc = 'Help',
      keys = { '?' },
      nomenu = true,
      run = function()
        require('perforated.ui.keys').help(p.actions, 'Diff tab')
      end,
    },
    {
      id = 'menu',
      desc = 'Action menu',
      keys = { '.', '<RightMouse>' },
      nomenu = true,
      run = function()
        require('perforated.ui.keys').menu(p.actions, p.view)
      end,
    },
  }
end
M._panel_actions = panel_actions -- for the generated help (scripts/gen_doc.lua)

--- Open the diff tab, unless every file is identical (then just say so). Only files that
--- differ get a diff; identical ones are listed under "Identical:" at the end of the panel.
--- `opts.extra` adds listed-only sections below it (shelf vs workspace: "Not in Shelf").
---@param ws perforated.Workspace
---@param title string
---@param entries perforated.DiffEntry[]
---@param opts { extra: { title: string, entries: perforated.DiffEntry[] }[]? }?
function M.open(ws, title, entries, opts)
  local extra = vim.tbl_filter(function(sec)
    return #sec.entries > 0
  end, (opts and opts.extra) or {})
  start_busy()
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
      finish_busy()
      local lines = {
        #entries == 1 and (title .. ': the file is identical')
          or ('%s: all %d files are identical'):format(title, #entries),
      }
      for _, sec in ipairs(extra) do -- one file per line, indented under the section name
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('%s (%d):'):format(sec.title, #sec.entries)
        for _, e in ipairs(sec.entries) do
          lines[#lines + 1] = '  ' .. e.label
        end
      end
      return require('perforated.ui.toast').show(
        'Perforce: identical, nothing to diff',
        lines,
        vim.log.levels.INFO
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
    open_tab(
      ws,
      title,
      differ,
      vim.list_extend({ { title = 'Identical', entries = identical } }, extra)
    )
  end)
end

---@param ws perforated.Workspace
---@param title string
---@param entries perforated.DiffEntry[]
---@param listed { title: string, entries: perforated.DiffEntry[] }[]  sections listed, not diffed
open_tab = function(ws, title, entries, listed)
  local origin_win = vim.api.nvim_get_current_win() -- where `o` opens a file
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local panel_buf = vim.api.nvim_get_current_buf()
  vim.bo[panel_buf].buftype = 'nofile'
  vim.bo[panel_buf].bufhidden = 'wipe'
  vim.bo[panel_buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, panel_buf, 'perforated://files/' .. title)
  local panel = vim.api.nvim_get_current_win()

  -- Panel content: the title, a row per file that differs (rows 3 … #entries + 2), then the
  -- listed-only sections. Rendered again when a revert takes a file out.
  local function render()
    local lines, dirs = { ' ' .. title, '' }, {}
    for _, e in ipairs(entries) do
      local row = #lines + 1
      lines[row], dirs[row] = panel_line(e, true)
    end
    local sections = {}
    for _, sec in ipairs(listed) do
      if #sec.entries > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = (' %s (%d):'):format(sec.title, #sec.entries)
        sections[#sections + 1] = { #lines - 1, #lines + #sec.entries - 1 }
        for _, e in ipairs(sec.entries) do
          lines[#lines + 1] = panel_line(e, false)
        end
      end
    end
    vim.bo[panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
    vim.bo[panel_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(panel_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(panel_buf, ns, 0, 0, { line_hl_group = 'PerforatedTitle' })
    for i = 1, #entries do
      vim.api.nvim_buf_set_extmark(
        panel_buf,
        ns,
        i + 1,
        1,
        { end_col = 10, hl_group = 'PerforatedAction' }
      )
      local col = dirs[i + 2]
      if col then
        vim.api.nvim_buf_set_extmark(
          panel_buf,
          ns,
          i + 1,
          col,
          { end_col = #lines[i + 2], hl_group = 'PerforatedDim' }
        )
      end
    end
    for _, s in ipairs(sections) do
      vim.api.nvim_buf_set_extmark(panel_buf, ns, s[1], 0, { line_hl_group = 'PerforatedSection' })
      for row = s[1] + 1, s[2] do
        vim.api.nvim_buf_set_extmark(panel_buf, ns, row, 0, { line_hl_group = 'PerforatedDim' })
      end
    end
  end
  render()

  vim.cmd('rightbelow vnew')
  local rwin = vim.api.nvim_get_current_win()
  local placeholder_r = vim.api.nvim_get_current_buf()
  vim.cmd('leftabove vnew')
  local lwin = vim.api.nvim_get_current_win()
  local placeholder_l = vim.api.nvim_get_current_buf()
  require('perforated.views.base').code_win(lwin)
  require('perforated.views.base').code_win(rwin)
  for _, b in ipairs({ placeholder_l, placeholder_r }) do
    vim.bo[b].bufhidden = 'wipe'
  end
  vim.api.nvim_win_set_width(panel, math.min(50, math.floor(vim.o.columns * 0.3)))
  vim.wo[panel][0].winfixwidth = true
  vim.wo[panel][0].number = false
  vim.wo[panel][0].relativenumber = false
  vim.wo[panel][0].signcolumn = 'no'
  vim.wo[panel][0].cursorline = true
  vim.wo[panel][0].wrap = false
  require('perforated.diff.look').apply({ [panel] = 'ui', [lwin] = 'code', [rwin] = 'code' })

  local state = { current = nil }
  local keyed = {} -- buffers given this tab's keys (the user's files too, scoped to the tab)

  local function close_tab()
    dv.close_tab(tab)
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
      return { buf = workspace_buf(s.path), label = s.label }
    end
    return s
  end

  local function show_entry(i)
    local e = entries[i]
    if not e or state.current == i or not vim.api.nvim_tabpage_is_valid(tab) then
      return
    end
    state.current = i
    for _, w in ipairs({ lwin, rwin }) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_call, w, function()
          vim.cmd('diffoff')
        end)
        dv.clear_header(w) -- before the buffer changes: the old one must not keep it
      end
    end
    local l, r = side(e.left), side(e.right)
    local lbuf, rbuf = dv.side_buf(ws, l), dv.side_buf(ws, r)
    for _, pair in ipairs({ { lwin, lbuf, l }, { rwin, rbuf, r } }) do
      local w, b, sd = pair[1], pair[2], pair[3]
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_set_buf(w, b)
        dv.header(w, ws, sd)
        dv.side_win(w)
        if not keyed[b] then
          keyed[b] = true
          dv.tab_key(tab, b, 'q', close_tab, 'Close diff tab')
          dv.change_keys(tab, b)
          dv.lookup_keys(tab, b, ws)
          dv.tab_key(tab, b, '<Tab>', function()
            M._step(state, 1)
          end, 'Next file')
          dv.tab_key(tab, b, '<S-Tab>', function()
            M._step(state, -1)
          end, 'Previous file')
        end
      end
    end
    dv.diffthis({ lwin, rwin })
    -- Each file opens at its first change, both sides in line — again once drawn (diff folds
    -- settle on the first redraw and can scroll a window).
    dv.align(rwin, lwin, true)
    vim.schedule(function()
      if state.current == i then
        dv.align(rwin, lwin, vim.w[rwin].perforated_first_change)
      end
    end)
    -- :diffoff / :diffthis fire OptionSet: a user hook may have reset the windows' colours.
    require('perforated.diff.look').apply({ [lwin] = 'code', [rwin] = 'code' }, { rebuild = false })
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
      -- The cursor stays on the file list (rows 3 … #entries + 2): any motion that leaves it
      -- (gg, G, a click on the title or the "Identical" section, a search) comes back.
      local row = vim.api.nvim_win_get_cursor(panel)[1]
      local clamped = math.max(3, math.min(row, #entries + 2))
      if clamped ~= row then
        vim.api.nvim_win_set_cursor(panel, { clamped, 0 })
      end
      show_entry(clamped - 2)
      state.update_footer()
    end,
  })
  -- Closing any of the three windows (`:q` in a diff side too) closes the whole tab.
  local closed = false
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = { tostring(panel), tostring(lwin), tostring(rwin) },
    callback = function()
      if closed then
        return
      end
      closed = true
      -- Now, while the windows exist: a closing window saves its options for its buffer.
      dv.clear_header(lwin)
      dv.clear_header(rwin)
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
        -- Buffers outlive the tab (revisions: bufhidden=hide; the user's files): drop its keys.
        dv.tab_keys_drop(tab, vim.tbl_keys(keyed))
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
  -- `o`: in the window the tab was opened from when it shows a file, else another file window
  -- of that tab, else a tab of its own (as describe's `o`).
  local function open(e)
    local r = e.right
    local target = r.path and r or (r.spec and r) or e.left
    local win
    if vim.api.nvim_win_is_valid(origin_win) then
      local otab = vim.api.nvim_win_get_tabpage(origin_win)
      for _, w in ipairs(vim.list_extend({ origin_win }, vim.api.nvim_tabpage_list_wins(otab))) do
        if
          vim.api.nvim_win_get_config(w).relative == ''
          and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ''
        then
          win = w
          break
        end
      end
    end
    if not win then
      return require('perforated.revs').open(ws, target)
    end
    vim.api.nvim_set_current_win(win)
    if target.path then
      vim.cmd('edit ' .. vim.fn.fnameescape(target.path))
    elseif target.spec then
      vim.api.nvim_win_set_buf(win, require('perforated.uri').buffer(ws, target.spec))
    end
  end

  -- `r`: asks as the client view does; the reverted file leaves the panel.
  local function revert(e)
    if
      require('perforated.ui.prompt').confirm(
        ('Revert %s? Local changes will be lost.'):format(e.client_file),
        '&Revert\n&Cancel',
        2
      ) ~= 1
    then
      return
    end
    require('perforated.checkout').revert(ws, { e.client_file }, false, function(ok)
      local i
      for k, x in ipairs(entries) do
        if x == e then
          i = k
        end
      end
      if not ok or not i or not vim.api.nvim_tabpage_is_valid(tab) then
        return
      end
      table.remove(entries, i)
      if #entries == 0 then
        return close_tab()
      end
      state.count = #entries
      render()
      state.current = nil
      local n = math.min(i, #entries)
      vim.api.nvim_win_set_cursor(panel, { n + 2, 0 })
      show_entry(n)
      state.update_footer()
    end)
  end

  local p = {
    ws = ws,
    step = function(delta)
      state.step(delta)
    end,
    focus = function()
      if state.current then
        vim.api.nvim_set_current_win(rwin)
      end
    end,
    close = close_tab,
    open = open,
    revert = revert,
  }
  local function node_at(row)
    local i = (row or vim.api.nvim_win_get_cursor(panel)[1]) - 2
    return entries[i] and { kind = 'file', item = entries[i] } or nil
  end
  p.view = {
    ws = ws,
    buf = panel_buf,
    win = panel,
    tree = {
      node_at = function(_, row)
        return node_at(row)
      end,
      marked = function()
        return {}
      end,
    },
  }
  p.actions = panel_actions(p)
  local keys = require('perforated.ui.keys')
  keys.attach(panel_buf, p.actions, p.view)
  local footer = require('perforated.ui.footer').attach(panel)
  state.update_footer = function()
    if vim.api.nvim_win_is_valid(panel) then
      footer:set(keys.footer(p.actions, node_at()))
    end
  end

  -- Panel keeps its width; the two diff windows share the rest equally.
  vim.cmd('wincmd =')
  vim.api.nvim_set_current_win(panel)
  vim.api.nvim_win_set_cursor(panel, { 3, 0 })
  show_entry(1)
  vim.api.nvim_set_current_win(panel)
  state.update_footer()
  finish_busy()
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
        left = base and {
          spec = base,
          label = r.haveRev and base == r.depotFile .. '#' .. r.haveRev and 'have' or nil,
        } or { empty = 'new file' },
        right = deleted and { empty = 'deleted' } or { path = r.clientFile },
        -- Revertable here only when it's this workspace's file (not another client's CL).
        client_file = label ~= r.clientFile and r.clientFile or nil,
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
  start_busy()
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
      left = base and { spec = base, label = 'base' } or { empty = 'new file' },
      right = f.action == 'delete' and { empty = 'deleted' }
        or { spec = f.depotFile .. '@=' .. item.change },
    }
  end
  M.open(ws, ('CL %s (shelved)'):format(item.change), entries)
end

--- A shelf against the workspace: every shelved file (left) next to its workspace file (right).
--- Files that aren't in the workspace (unmapped or not synced) show an empty side. Opened
--- files (any changelist) that aren't in the shelf are listed under "Not in Shelf".
---@param ws perforated.Workspace
---@param change string
---@param shelved table[]?  the shelf's files (fetched when nil)
function M.open_shelf_vs_workspace(ws, change, shelved)
  start_busy()
  if not shelved then
    return cls.shelved_files(ws, { change }, function(by)
      M.open_shelf_vs_workspace(ws, change, by[change] or {})
    end)
  end
  local depot = vim.tbl_map(function(f)
    return f.depotFile
  end, shelved)
  -- Two queries at once: where the shelved files are, and what is opened.
  local map, opened, failed
  local function relative(path)
    if ws.root and path:sub(1, #ws.root + 1) == ws.root .. '/' then
      return path:sub(#ws.root + 2)
    end
    return path
  end
  local function done()
    if not map or not opened then
      return
    end
    if failed then
      return notify(('CL %s: %s'):format(change, failed), vim.log.levels.WARN)
    end
    local in_shelf = {}
    for _, d in ipairs(depot) do
      in_shelf[d] = true
    end
    local not_in_shelf = {}
    for _, r in ipairs(opened) do
      if r.depotFile and not in_shelf[r.depotFile] then
        not_in_shelf[#not_in_shelf + 1] =
          { label = relative(r.clientFile or r.depotFile), action = r.action }
      end
    end
    table.sort(not_in_shelf, function(a, b)
      return a.label < b.label
    end)
    local entries = {}
    for _, f in ipairs(shelved) do
      local path = map[f.depotFile]
      entries[#entries + 1] = {
        label = path and relative(path) or f.depotFile,
        action = f.action,
        left = (f.action == 'delete' or f.action == 'move/delete') and { empty = 'deleted' }
          or { spec = f.depotFile .. '@=' .. change },
        right = (path and vim.uv.fs_stat(path)) and { path = path }
          or { empty = 'not in workspace' },
      }
    end
    table.sort(entries, function(a, b)
      return a.label < b.label
    end)
    M.open(
      ws,
      ('CL %s (shelved vs workspace)'):format(change),
      entries,
      { extra = { { title = 'Not in Shelf', entries = not_in_shelf } } }
    )
  end
  require('perforated.revs').where(ws, depot, function(m)
    map = m
    done()
  end)
  p4.fstat_opened(ws, {}, function(recs, res)
    opened = recs or {}
    failed = not recs and (res.errors[1] or vim.trim(res.stderr or '')) or nil
    done()
  end)
end

--- Every opened file of the workspace.
---@param ws perforated.Workspace
function M.open_opened(ws)
  start_busy()
  p4.fstat_opened(ws, {}, function(recs, res)
    local title = 'opened files · ' .. (ws:client() or ws.key)
    if not recs then
      return notify(
        title .. ': ' .. (res.errors[1] or vim.trim(res.stderr or '')),
        vim.log.levels.WARN
      )
    end
    M.open(ws, title, opened_entries(ws, recs))
  end)
end

return M
