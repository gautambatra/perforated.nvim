--- Action registry for plugin views. One definition per action drives the buffer keymaps, the
--- `.` action menu, the `?` help and the always-visible footer, so they can't drift apart.
---
---   {
---     id = 'diff', desc = 'Diff', keys = { 'd' }, p4v = { '<C-d>' },
---     kinds = { opened_file = true },      -- node kinds it applies to (nil = any)
---     when = function(item, node) … end,   -- optional extra condition
---     run = function(items, ctx) … end,    -- items: marked items, else the cursor's item
---     multi = true,                        -- accepts several (marked) items
---     footer = 10,                         -- show in footer (lower = earlier)
---     footer_when = function(item, node) … end, -- optional: in the footer only here (the
---                                          -- key still works wherever the action applies)
---   }
---
--- A doubled key (`dd`) shares its first key with single-key actions without delaying them:
--- there's no `dd` mapping (which would make `d` wait 'timeoutlen'); `d` itself reads a second
--- key, and only on a node where no single-key `d` action applies.
---
--- Users override keys per action: `keys = { diff = { 'D' } }` or `{ diff = false }`; the
--- P4V layer (`keys.p4v = false`) can be disabled as a whole.

local M = {}

---@class perforated.Action
---@field id string
---@field desc string
---@field keys string[]?
---@field p4v string[]?
---@field kinds table<string, boolean>?
---@field when (fun(item: any, node: perforated.TreeNode): boolean)?
---@field run fun(items: any[], ctx: table)
---@field multi boolean?
---@field footer integer?
---@field footer_when (fun(item: any, node: perforated.TreeNode?): boolean)?
---@field footer_desc string?  a shorter label for the footer
---@field nomenu boolean|'layout'|nil  hide from the `.` menu (navigation keys); 'layout': only
---  where a menu layout lists it

--- Effective keys of an action after user overrides.
---@param a perforated.Action
---@return string[]
function M.keys_of(a)
  local cfg = require('perforated.config').get().keys or {}
  local override = cfg[a.id]
  if override == false then
    return {}
  end
  local out = vim.deepcopy(type(override) == 'table' and override or (a.keys or {}))
  if cfg.p4v ~= false and type(override) ~= 'table' then
    vim.list_extend(out, a.p4v or {})
  end
  return out
end

---@param a perforated.Action
---@param node perforated.TreeNode?
---@return boolean
function M.applies(a, node)
  if a.kinds then
    if not node or not a.kinds[node.kind] then
      return false
    end
  end
  if a.when then
    return a.when(node and node.item, node) and true or false
  end
  return true
end

---@class perforated.ActionCtx
---@field tree perforated.Tree
---@field node perforated.TreeNode?
---@field nodes perforated.TreeNode[]
---@field view table

--- Run an action on the selected nodes (visual mode), else the marked ones (if the action
--- takes several and marks exist), else the cursor's node.
---@param a perforated.Action
---@param view table { tree = perforated.Tree }
---@param selected perforated.TreeNode[]?  rows selected in visual mode
function M.dispatch(a, view, selected)
  local tree = view.tree
  local node = tree:node_at()
  local nodes = {}
  if a.multi then
    for _, n in ipairs(selected or tree:marked()) do
      if M.applies(a, n) then
        nodes[#nodes + 1] = n
      end
    end
    if selected then
      -- A selected changelist and its selected files: the changelist once (files_of would
      -- count its files twice).
      local set = {}
      for _, n in ipairs(nodes) do
        set[n] = true
      end
      nodes = vim.tbl_filter(function(n)
        local p = n.parent
        while p do
          if set[p] then
            return false
          end
          p = p.parent
        end
        return true
      end, nodes)
    end
  end
  if #nodes == 0 then
    if not M.applies(a, node) then
      local keys = M.keys_of(a)
      return require('perforated.ui.toast').notify(
        ('[perforated] %s (%s) does not apply here'):format(a.desc, keys[1] or a.id),
        vim.log.levels.INFO
      )
    end
    nodes = node and { node } or {}
  end
  local items = vim.tbl_map(function(n)
    return n.item
  end, nodes)
  a.run(items, { tree = tree, node = node, nodes = nodes, view = view })
end

--- Move the cursor to the mouse position, if the mouse is over a window showing `buf`.
---@param buf integer
---@return boolean moved
function M.cursor_to_mouse(buf)
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line < 1 or vim.api.nvim_win_get_buf(pos.winid) ~= buf then
    return false
  end
  vim.api.nvim_set_current_win(pos.winid)
  vim.api.nvim_win_set_cursor(pos.winid, { pos.line, math.max(pos.column - 1, 0) })
  return true
end

--- The rows selected in visual mode (leaving it), as nodes.
---@param view table { tree = perforated.Tree }
---@return perforated.TreeNode[]
function M.selection(view)
  local a, b = vim.fn.line('v'), vim.fn.line('.')
  if a > b then
    a, b = b, a
  end
  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  local out = {}
  for row = a, b do
    out[#out + 1] = view.tree:node_at(row)
  end
  return out
end

--- Install buffer-local keymaps for a view's actions.
---@param buf integer
---@param actions perforated.Action[]
---@param view table
function M.attach(buf, actions, view)
  -- One mapping per key; several actions may share a key for different node kinds (e.g. `x`
  -- reverts a file but cancels a running scan), so pick the first that applies.
  local by_key, order = {}, {}
  local doubles = {} ---@type table<string, perforated.Action[]>  'd' → actions on `dd`
  local function key(lhs)
    if not by_key[lhs] then
      by_key[lhs] = {}
      order[#order + 1] = lhs
    end
  end
  for _, a in ipairs(actions) do
    for _, lhs in ipairs(M.keys_of(a)) do
      local c = #lhs == 2 and lhs:sub(1, 1) == lhs:sub(2, 2) and lhs:sub(1, 1) or nil
      if c and c:match('%a') then
        doubles[c] = doubles[c] or {}
        table.insert(doubles[c], a)
        key(c)
      else
        key(lhs)
        table.insert(by_key[lhs], a)
      end
    end
  end
  -- Visual mode: keys of actions that take several items act on the selected rows (like marks).
  for _, lhs in ipairs(order) do
    local multi = vim.tbl_filter(function(a)
      return a.multi
    end, by_key[lhs])
    if #multi > 0 and not lhs:find('Mouse', 1, true) then
      vim.api.nvim_buf_set_keymap(buf, 'x', lhs, '', {
        noremap = true,
        nowait = true,
        desc = 'perforated: ' .. multi[1].desc .. ' (selection)',
        callback = function()
          local sel = M.selection(view)
          for _, a in ipairs(multi) do
            for _, n in ipairs(sel) do
              if M.applies(a, n) then
                return M.dispatch(a, view, sel)
              end
            end
          end
          require('perforated.ui.toast').notify(
            ('[perforated] %s (%s) does not apply to the selection'):format(multi[1].desc, lhs),
            vim.log.levels.INFO
          )
        end,
      })
    end
  end
  for _, lhs in ipairs(order) do
    local list = by_key[lhs]
    local mouse = lhs:find('Mouse', 1, true) ~= nil
    -- Raw API: vim.keymap.set's argument processing costs ~50µs per map on first paint.
    vim.api.nvim_buf_set_keymap(buf, 'n', lhs, '', {
      noremap = true,
      nowait = true,
      desc = 'perforated: ' .. (list[1] or doubles[lhs][1]).desc,
      callback = function()
        -- A mapped click (right-click → menu) replaces Vim's own cursor move: act on the line
        -- that was clicked, not wherever the cursor was. Clicks outside the view do nothing.
        if mouse and not M.cursor_to_mouse(buf) then
          return
        end
        local node = view.tree:node_at()
        local marked = view.tree:marked()
        local function mark_applies(a)
          for _, n in ipairs(marked) do
            if M.applies(a, n) then
              return true
            end
          end
          return false
        end
        for _, a in ipairs(list) do
          if M.applies(a, node) or (a.multi and mark_applies(a)) then
            return M.dispatch(a, view)
          end
        end
        for _, a in ipairs(doubles[lhs] or {}) do
          if M.applies(a, node) then
            -- `dd`: only here does `d` wait for its second key.
            local ok, second = pcall(vim.fn.getcharstr)
            if ok and second == lhs then
              return M.dispatch(a, view)
            end
            return
          end
        end
        if list[1] then
          M.dispatch(list[1], view) -- reports "does not apply here"
        elseif doubles[lhs] then
          M.dispatch(doubles[lhs][1], view)
        end
      end,
    })
  end
end

--- Actions valid for a node, in definition order.
---@param actions perforated.Action[]
---@param node perforated.TreeNode?
---@return perforated.Action[]
function M.valid(actions, node)
  return vim.tbl_filter(function(a)
    return not a.nomenu and M.applies(a, node) -- ('layout' ones only through a layout)
  end, actions)
end

--- A Ctrl shortcut as people write it: `<C-d>` → `Ctrl+D`, `<C-S-t>` → `Ctrl+Shift+T`.
---@param lhs string
---@return string? nil when `lhs` isn't a Ctrl key
function M.ctrl_label(lhs)
  local mods, key = lhs:match('^<(.-%-)([^-]+)>$')
  if not mods or not mods:find('C-', 1, true) then
    return nil
  end
  local out = { 'Ctrl' }
  if mods:find('S-', 1, true) then
    out[#out + 1] = 'Shift'
  end
  if mods:find('[AM]%-') then
    out[#out + 1] = 'Alt'
  end
  out[#out + 1] = #key == 1 and key:upper() or key
  return table.concat(out, '+')
end

--- Menu entries for a node (each with its Ctrl shortcut as `hint`, e.g. `Ctrl+D`, shown
--- right-aligned): the valid actions, in definition order — or, when the view has a
--- `menu_layout` for the node's kind, in that order. A layout lists action ids, `'-'` for a
--- separator, or `{ id, label }` to rename an entry in that menu only; it is authoritative, so
--- actions it leaves out stay on their keys but aren't offered. Invalid entries are skipped and
--- separators collapse (never first, last or doubled).
---@param actions perforated.Action[]
---@param node perforated.TreeNode?
---@param layouts table<string, (string|string[])[]>?  node kind → layout
---@return perforated.MenuItem[]
function M.menu_items(actions, node, layouts)
  local function item(a, label)
    local keys = M.keys_of(a)
    -- Ctrl shortcuts (P4V's) in the right-hand column, unless one is already the key column's.
    local ctrl = {}
    for i = 2, #keys do
      ctrl[#ctrl + 1] = M.ctrl_label(keys[i])
    end
    local hint = #ctrl > 0 and not M.ctrl_label(keys[1]) and table.concat(ctrl, ', ') or nil
    return { key = keys[1] or a.id, label = label or a.desc, hint = hint, value = a }
  end
  local layout = node and layouts and layouts[node.kind]
  local items = {}
  if not layout then
    for _, a in ipairs(M.valid(actions, node)) do
      items[#items + 1] = item(a)
    end
    return items
  end
  local by_id = {}
  for _, a in ipairs(actions) do
    by_id[a.id] = by_id[a.id] or a
  end
  local sep = false
  for _, e in ipairs(layout) do
    if e == '-' then
      sep = #items > 0
    else
      local id, label = e, nil
      if type(e) == 'table' then
        id, label = e[1], e[2]
      end
      local a = by_id[id]
      if a and a.nomenu ~= true and M.applies(a, node) then
        if sep then
          items[#items + 1] = { separator = true }
          sep = false
        end
        items[#items + 1] = item(a, label)
      end
    end
  end
  return items
end

--- `.` / right-click: menu of the actions valid for the cursor's node.
---@param actions perforated.Action[]
---@param view table  { tree, menu_layout? }
function M.menu(actions, view)
  local node = view.tree:node_at()
  local items = M.menu_items(actions, node, view.menu_layout)
  if #items == 0 then
    return require('perforated.ui.toast').notify(
      '[perforated] no actions here',
      vim.log.levels.INFO
    )
  end
  local choice = require('perforated.ui.float').menu({
    title = 'Actions',
    items = items,
    relative = 'cursor',
  })
  if choice then
    M.dispatch(choice.value, view)
  end
end

--- Between an action's alternative keys in the help (`l · <Tab> · <CR>`): not a key itself,
--- so alternatives don't read as one key sequence.
M.KEY_SEP = ' · '

---@alias perforated.HelpSection { [1]: string, [2]: (string|{ [1]: string, [2]: string })[] }
---  a title and its actions in order: an id, or { id, help text }

--- Rows of the `?` help: every action with keys, as `{ keys, desc }`. With `sections`, grouped
--- under `{ section = title }` rows in that order; within a section, actions sharing their
--- keys (`gs` on a file, a changelist, a section) make one row, worded by the first entry.
--- Actions with keys that no section lists come last, under "Other".
---@param actions perforated.Action[]
---@param sections perforated.HelpSection[]?
---@return ({ [1]: string, [2]: string }|{ section: string })[]
function M.help_rows(actions, sections)
  local rows = {}
  local function keys_str(a)
    return table.concat(M.keys_of(a), M.KEY_SEP)
  end
  if not sections then
    for _, a in ipairs(actions) do
      local k = keys_str(a)
      if k ~= '' then
        rows[#rows + 1] = { k, a.desc }
      end
    end
    return rows
  end
  local by_id, used = {}, {}
  for _, a in ipairs(actions) do
    by_id[a.id] = by_id[a.id] or a
  end
  local function section(title, entries)
    local seen, out = {}, {}
    for _, e in ipairs(entries) do
      local id, text = e, nil
      if type(e) == 'table' then
        id, text = e[1], e[2]
      end
      local a = by_id[id]
      if a then
        used[id] = true
        local k = keys_str(a)
        if k ~= '' and not seen[k] then
          seen[k] = true
          out[#out + 1] = { k, text or a.desc }
        end
      end
    end
    if #out > 0 then
      rows[#rows + 1] = { section = title }
      vim.list_extend(rows, out)
    end
  end
  for _, s in ipairs(sections) do
    section(s[1], s[2])
  end
  local rest = {}
  for _, a in ipairs(actions) do
    if not used[a.id] then
      rest[#rest + 1] = a.id
    end
  end
  section('Other', rest)
  return rows
end

--- `?`: floating help listing every action with all its keys (by section, when given).
---@param actions perforated.Action[]
---@param title string
---@param sections perforated.HelpSection[]?
function M.help(actions, title, sections)
  local rows = M.help_rows(actions, sections)
  local width = 0
  for _, r in ipairs(rows) do
    if r[1] then
      width = math.max(width, vim.fn.strdisplaywidth(r[1]))
    end
  end
  local lines, marks = {}, {}
  for _, r in ipairs(rows) do
    if r.section then
      if #lines > 0 then
        lines[#lines + 1] = ''
      end
      lines[#lines + 1] = ' ' .. r.section
      marks[#marks + 1] = { #lines - 1, 1, 1 + #r.section, 'PerforatedSection' }
    else
      lines[#lines + 1] = ('   %s%s  %s'):format(
        r[1],
        (' '):rep(width - vim.fn.strdisplaywidth(r[1])),
        r[2]
      )
      -- each key in the key colour, the separators between alternatives dimmed
      local col = 3
      for i, k in ipairs(vim.split(r[1], M.KEY_SEP, { plain = true })) do
        if i > 1 then
          marks[#marks + 1] = { #lines - 1, col + 1, col + #M.KEY_SEP - 1, 'PerforatedDim' }
          col = col + #M.KEY_SEP
        end
        marks[#marks + 1] = { #lines - 1, col, col + #k, 'PerforatedKey' }
        col = col + #k
      end
    end
  end
  if not sections then -- a flat list: no indent for headings
    for i, l in ipairs(lines) do
      lines[i] = l:sub(3)
    end
    for _, m in ipairs(marks) do
      m[2], m[3] = m[2] - 2, m[3] - 2
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, require('perforated.ui.tree').ns, m[1], m[2], {
      end_col = m[3],
      hl_group = m[4],
    })
  end
  local w = 0
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(l) + 1)
  end
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    width = math.min(w, vim.o.columns - 4),
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' — keys ',
    title_pos = 'center',
  })
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  require('perforated.ui.stack').register(win)
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', lhs, '<cmd>close<cr>', { buffer = buf, nowait = true })
  end
end

--- Footer text: the most useful valid actions for the node, by `footer` order.
---@param actions perforated.Action[]
---@param node perforated.TreeNode?
---@param max integer?
---@return { [1]: string, [2]: string }[] chunks
function M.footer(actions, node, max)
  local list = vim.tbl_filter(function(a)
    return a.footer
      and M.applies(a, node)
      and (not a.footer_when or a.footer_when(node and node.item, node))
  end, actions)
  table.sort(list, function(a, b)
    return a.footer < b.footer
  end)
  local chunks = {}
  for i = 1, math.min(#list, max or 8) do
    local keys = M.keys_of(list[i])
    if keys[1] then
      chunks[#chunks + 1] = { ' ' .. keys[1], 'PerforatedBarBold' }
      chunks[#chunks + 1] =
        { ' ' .. (list[i].footer_desc or list[i].desc:lower()) .. ' ', 'PerforatedBarText' }
    end
  end
  for _, a in ipairs(actions) do
    if a.id == 'menu' then
      chunks[#chunks + 1] = { ' ' .. (M.keys_of(a)[1] or '.'), 'PerforatedBarBold' }
    end
  end
  chunks[#chunks + 1] = { ' actions ', 'PerforatedBarText' }
  chunks[#chunks + 1] = { ' ?', 'PerforatedBarBold' }
  chunks[#chunks + 1] = { ' help', 'PerforatedBarText' }
  return chunks
end

return M
