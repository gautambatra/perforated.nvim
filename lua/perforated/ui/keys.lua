--- Action registry for plugin views. One definition per action drives the buffer keymaps, the
--- `<Space>` action menu, the `?` help and the always-visible footer, so they can't drift apart.
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
---@field nomenu boolean?       hide from the <Space> menu (navigation keys)

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
      return vim.notify(
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
    -- Raw API: vim.keymap.set's argument processing costs ~50µs per map on first paint.
    vim.api.nvim_buf_set_keymap(buf, 'n', lhs, '', {
      noremap = true,
      nowait = true,
      desc = 'perforated: ' .. list[1].desc,
      callback = function()
        local node = view.tree:node_at()
        for _, a in ipairs(list) do
          if M.applies(a, node) or (a.multi and #view.tree:marked() > 0) then
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

--- `<Space>`: menu of the actions valid for the cursor's node.
---@param actions perforated.Action[]
---@param view table
function M.menu(actions, view)
  local node = view.tree:node_at()
  local valid = M.valid(actions, node)
  if #valid == 0 then
    return vim.notify('[perforated] no actions here', vim.log.levels.INFO)
  end
  local items = {}
  for _, a in ipairs(valid) do
    local keys = M.keys_of(a)
    items[#items + 1] = { key = keys[1] or a.id, label = a.desc, value = a }
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
  vim.wo[win].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
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
  chunks[#chunks + 1] = { ' <Space>', 'PerforatedKey' }
  chunks[#chunks + 1] = { ' actions ', 'PerforatedDim' }
  chunks[#chunks + 1] = { ' ?', 'PerforatedKey' }
  chunks[#chunks + 1] = { ' help', 'PerforatedDim' }
  return chunks
end

return M
