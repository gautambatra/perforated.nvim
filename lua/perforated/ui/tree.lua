--- Foldable tree renderer for plugin buffers (client view, describe, …).
---
--- Nodes are plain tables:
---   { id = 'cl:123', kind = 'change', text = { { 'CL 123', 'PerforatedChangelist' }, … },
---     item = <domain object>, children = { … } | nil, open = true|false (default fold state),
---     on_open = fun(node) (lazy expansion, e.g. workspace reconcile) }
---
--- Fold state is tree state (not Vim folds) and survives refreshes by node id; the cursor stays
--- on the same node across re-renders. Rendering is a single `nvim_buf_set_lines`; highlights
--- are applied by a decoration provider for the rows actually on screen (ephemeral extmarks),
--- so the cost doesn't grow with the number of rows.

local M = {}

local ns = vim.api.nvim_create_namespace('perforated.tree')

local trees = {} ---@type table<integer, perforated.Tree>  buf → tree (for the provider)

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    return trees[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    local t = trees[buf]
    local hls = t and t.row_hls[row]
    if hls then
      -- flat: { start, end, group, start, end, group, … }
      for i = 1, #hls, 3 do
        vim.api.nvim_buf_set_extmark(buf, ns, row, hls[i], {
          end_col = hls[i + 1],
          hl_group = hls[i + 2],
          ephemeral = true,
        })
      end
    end
  end,
})

---@class perforated.TreeNode
---@field id string
---@field kind string
---@field text { [1]: string, [2]: string? }[]
---@field item any
---@field children perforated.TreeNode[]?
---@field open boolean?          default fold state (children shown)
---@field on_open fun(node: perforated.TreeNode)?  called the first time the node is expanded
---@field parent perforated.TreeNode?   set by render
---@field depth integer?                set by render

---@class perforated.Tree
---@field buf integer
---@field roots perforated.TreeNode[]
---@field rows perforated.TreeNode[]    row (1-based) → node
---@field folds table<string, boolean>  id → open (user overrides)
---@field by_id table<string, perforated.TreeNode>
---@field marks table<string, boolean>  id → marked
local Tree = {}
Tree.__index = Tree

---@param buf integer
---@return perforated.Tree
function M.new(buf)
  local t = setmetatable(
    { buf = buf, roots = {}, rows = {}, folds = {}, by_id = {}, marks = {}, row_hls = {} },
    Tree
  )
  trees[buf] = t
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      trees[buf] = nil
    end,
  })
  return t
end

---@param node perforated.TreeNode
---@return boolean
function Tree:is_open(node)
  local o = self.folds[node.id]
  if o == nil then
    o = node.open ~= false
  end
  return o
end

local function glyphs()
  if require('perforated.ui.icons').style() == 'nerd' then
    return { open = ' ', closed = ' ', leaf = '  ', mark = '● ' }
  end
  return { open = 'v ', closed = '> ', leaf = '  ', mark = '* ' }
end

--- Replace the tree content and redraw (keeps folds, marks and the cursor's node).
---@param roots perforated.TreeNode[]
function Tree:set(roots)
  self.roots = roots
  self:render()
end

--- Render visible nodes into the buffer.
function Tree:render()
  local buf = self.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Remember which node the cursor is on (in any window showing the buffer).
  local keep = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local node = self.rows[row]
    keep[win] = { id = node and node.id, row = row }
  end

  local g = glyphs()
  -- Only a handful of distinct prefixes exist (depth × fold state × mark): build each once.
  local prefixes = {}
  local function prefix_for(depth, state, marked)
    local k = depth * 8 + state * 2 + (marked and 1 or 0)
    local p = prefixes[k]
    if not p then
      local glyph = state == 0 and g.leaf or (state == 1 and g.open or g.closed)
      p = ('  '):rep(depth) .. glyph .. (marked and g.mark or '')
      prefixes[k] = p
    end
    return p
  end
  local lines, row_hls, rows, by_id, row_by_id = {}, {}, {}, {}, {}
  local parts = {} -- scratch, reused for every row
  local function walk(nodes, depth, parent)
    for _, node in ipairs(nodes) do
      node.depth, node.parent = depth, parent
      by_id[node.id] = node
      local has_children = node.children ~= nil
      local open = has_children and self:is_open(node)
      local marked = self.marks[node.id]
      local prefix = prefix_for(depth, has_children and (open and 1 or 2) or 0, marked)
      local np, col = 1, #prefix
      parts[1] = prefix
      local hls, nh = {}, 0
      if marked then
        hls[1], hls[2], hls[3] = #prefix - #g.mark, #prefix, 'PerforatedMark'
        nh = 3
      end
      for _, chunk in ipairs(node.text) do
        local t = chunk[1] or ''
        np = np + 1
        parts[np] = t
        local len = #t
        if chunk[2] and len > 0 then
          hls[nh + 1], hls[nh + 2], hls[nh + 3] = col, col + len, chunk[2]
          nh = nh + 3
        end
        col = col + len
      end
      row_hls[#lines] = hls -- 0-based row of the line about to be added
      lines[#lines + 1] = table.concat(parts, '', 1, np)
      rows[#lines] = node
      row_by_id[node.id] = #lines
      if open then
        walk(node.children, depth + 1, node)
      end
    end
  end
  walk(self.roots, 0, nil)
  if #lines == 0 then
    lines = { '' }
  end

  self.rows, self.by_id, self.row_by_id, self.row_hls = rows, by_id, row_by_id, row_hls
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  for win, k in pairs(keep) do
    if vim.api.nvim_win_is_valid(win) then
      local row = k.id and self:row_of(k.id) or math.min(k.row, #lines)
      pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    end
  end
end

---@param id string
---@return integer? row
function Tree:row_of(id)
  return self.row_by_id and self.row_by_id[id]
end

---@param row integer?
---@return perforated.TreeNode?
function Tree:node_at(row)
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  return self.rows[row]
end

--- Expand a node (runs its lazy loader the first time).
---@param node perforated.TreeNode
function Tree:open(node)
  if not node.children then
    return
  end
  local first = self.folds[node.id] == nil and node.open == false
  self.folds[node.id] = true
  if node.on_open and (first or not node.loaded) then
    node.loaded = true
    node.on_open(node)
  end
  self:render()
end

---@param node perforated.TreeNode
function Tree:close(node)
  if node.children then
    self.folds[node.id] = false
    self:render()
  end
end

---@param node perforated.TreeNode
function Tree:toggle(node)
  if self:is_open(node) then
    self:close(node)
  else
    self:open(node)
  end
end

--- `h`: collapse the node, or jump to (and collapse) its parent when it has no open children.
function Tree:collapse_at_cursor()
  local node = self:node_at()
  if not node then
    return
  end
  if node.children and self:is_open(node) then
    return self:close(node)
  end
  if node.parent then
    self:close(node.parent)
    local row = self:row_of(node.parent.id)
    if row then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
    end
  end
end

--- Jump to the next/previous top-level node (section).
---@param forward boolean
function Tree:jump_section(forward)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local rows = {}
  for row, node in pairs(self.rows) do
    if node.depth == 0 then
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)
  local target
  if forward then
    for _, r in ipairs(rows) do
      if r > cur then
        target = r
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

--- Toggle the mark on the cursor's node (for multi-item actions).
---@param on boolean? nil = toggle
function Tree:mark(on)
  local node = self:node_at()
  if not node then
    return
  end
  if on == nil then
    on = not self.marks[node.id]
  end
  self.marks[node.id] = on or nil
  self:render()
end

--- Marked nodes that are still present.
---@return perforated.TreeNode[]
function Tree:marked()
  local out = {}
  for id in pairs(self.marks) do
    if self.by_id[id] then
      out[#out + 1] = self.by_id[id]
    end
  end
  table.sort(out, function(a, b)
    return (self:row_of(a.id) or 0) < (self:row_of(b.id) or 0)
  end)
  return out
end

function Tree:clear_marks()
  self.marks = {}
  self:render()
end

M.ns = ns

return M
