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
---   }
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
---@field nomenu boolean?       hide from the `.` menu (navigation keys)

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

--- Run an action on the marked nodes (if the action takes several and marks exist), else on
--- the cursor's node.
---@param a perforated.Action
---@param view table { tree = perforated.Tree }
function M.dispatch(a, view)
  local tree = view.tree
  local node = tree:node_at()
  local nodes = {}
  if a.multi then
    for _, n in ipairs(tree:marked()) do
      if M.applies(a, n) then
        nodes[#nodes + 1] = n
      end
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

--- Install buffer-local keymaps for a view's actions.
---@param buf integer
---@param actions perforated.Action[]
---@param view table
function M.attach(buf, actions, view)
  -- One mapping per key; several actions may share a key for different node kinds (e.g. `x`
  -- reverts a file but cancels a running scan), so pick the first that applies.
  local by_key, order = {}, {}
  for _, a in ipairs(actions) do
    for _, lhs in ipairs(M.keys_of(a)) do
      if not by_key[lhs] then
        by_key[lhs] = {}
        order[#order + 1] = lhs
      end
      table.insert(by_key[lhs], a)
    end
  end
  for _, lhs in ipairs(order) do
    local list = by_key[lhs]
    local mouse = lhs:find('Mouse', 1, true) ~= nil
    -- Raw API: vim.keymap.set's argument processing costs ~50µs per map on first paint.
    vim.api.nvim_buf_set_keymap(buf, 'n', lhs, '', {
      noremap = true,
      nowait = true,
      desc = 'perforated: ' .. list[1].desc,
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
        M.dispatch(list[1], view) -- reports "does not apply here"
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
    return not a.nomenu and M.applies(a, node)
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
      if a and not a.nomenu and M.applies(a, node) then
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

--- `?`: floating help listing every action with all its keys.
---@param actions perforated.Action[]
---@param title string
function M.help(actions, title)
  local lines = {}
  local width = 0
  local rows = {}
  for _, a in ipairs(actions) do
    local keys = table.concat(M.keys_of(a), ' ')
    if keys ~= '' then
      rows[#rows + 1] = { keys, a.desc }
      width = math.max(width, vim.fn.strdisplaywidth(keys))
    end
  end
  for _, r in ipairs(rows) do
    lines[#lines + 1] = (' %s%s  %s'):format(
      r[1],
      (' '):rep(width - vim.fn.strdisplaywidth(r[1])),
      r[2]
    )
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for i = 1, #lines do
    vim.api.nvim_buf_set_extmark(buf, require('perforated.ui.tree').ns, i - 1, 1, {
      end_col = 1 + #rows[i][1],
      hl_group = 'PerforatedKey',
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
    return a.footer and M.applies(a, node)
  end, actions)
  table.sort(list, function(a, b)
    return a.footer < b.footer
  end)
  local chunks = {}
  for i = 1, math.min(#list, max or 8) do
    local keys = M.keys_of(list[i])
    if keys[1] then
      chunks[#chunks + 1] = { ' ' .. keys[1], 'PerforatedKey' }
      chunks[#chunks + 1] = { ' ' .. list[i].desc:lower() .. ' ', 'PerforatedDim' }
    end
  end
  for _, a in ipairs(actions) do
    if a.id == 'menu' then
      chunks[#chunks + 1] = { ' ' .. (M.keys_of(a)[1] or '.'), 'PerforatedKey' }
    end
  end
  chunks[#chunks + 1] = { ' actions ', 'PerforatedDim' }
  chunks[#chunks + 1] = { ' ?', 'PerforatedKey' }
  chunks[#chunks + 1] = { ' help', 'PerforatedDim' }
  return chunks
end

return M
