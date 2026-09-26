-- Generate doc/perforated.txt from the code: commands (commands.lua), view keys (the action
-- registries), <Plug> maps and the preset (keymaps.lua), config defaults (config.lua) and
-- highlight groups (hl.lua). Run with `make doc`; tests/test_docs.lua fails when it's stale.
--
--   nvim --headless --noplugin -u tests/minimal_init.lua -l scripts/gen_doc.lua [out]

local out_path = arg[1] or 'doc/perforated.txt'
require('perforated.config')._reset()

local W = 78
local L = {}
local function add(s)
  L[#L + 1] = s or ''
end
local function rule()
  add(('='):rep(W))
end
local function header(title, tag)
  add()
  rule()
  local pad = W - #title - #tag - 2
  add(title .. (' '):rep(math.max(1, pad)) .. '*' .. tag .. '*')
  add()
end
local function wrap(text, indent)
  indent = indent or ''
  local line = indent
  for word in text:gmatch('%S+') do
    if #line + #word + 1 > W and line ~= indent then
      add(line)
      line = indent .. word
    else
      line = (line == indent) and (indent .. word) or (line .. ' ' .. word)
    end
  end
  if line ~= indent then
    add(line)
  end
end

-- A stub workspace/view: action builders only capture it (nothing runs).
local ws = {
  key = 'doc',
  mode = 'config',
  client = function()
    return 'client'
  end,
  user = function()
    return 'user'
  end,
}
local function stub()
  return {
    ws = ws,
    tree = {
      node_at = function() end,
      marked = function()
        return {}
      end,
    },
    item = {},
    data = { files = {}, shelved = {} },
  }
end

local keys = require('perforated.ui.keys')

local function key_table(actions)
  local rows, width = {}, 0
  for _, a in ipairs(actions) do
    local k = table.concat(keys.keys_of(a), ' ')
    if k ~= '' then
      rows[#rows + 1] = { k, a.desc }
      width = math.max(width, vim.fn.strdisplaywidth(k))
    end
  end
  width = math.min(width, 26)
  for _, r in ipairs(rows) do
    local k = r[1]
    if vim.fn.strdisplaywidth(k) > width then
      add('  ' .. k)
      add('  ' .. (' '):rep(width) .. '  ' .. r[2])
    else
      add('  ' .. k .. (' '):rep(width - vim.fn.strdisplaywidth(k)) .. '  ' .. r[2])
    end
  end
end

-- ---------------------------------------------------------------------------------------------

add('*perforated.txt*  Perforce for Neovim: fast, light, asynchronous')
add()
add('This file is generated from the code by `make doc` (scripts/gen_doc.lua).')
add('The README has the feature tour: https://github.com/gautambatra/perforated.nvim')

header('CONTENTS', 'perforated-contents')
for _, s in ipairs({
  { 'Introduction', 'perforated-intro' },
  { 'Commands', 'perforated-commands' },
  { 'Keys in plugin views', 'perforated-keys' },
  { 'Keymaps for your files', 'perforated-keymaps' },
  { 'Configuration', 'perforated-config' },
  { 'Highlight groups', 'perforated-highlights' },
  { 'Events', 'perforated-events' },
}) do
  add(('  %-40s|%s|'):format(s[1], s[2]))
end

header('INTRODUCTION', 'perforated-intro')
wrap(
  'perforated.nvim integrates Perforce (Helix Core) into Neovim. Every p4 call is asynchronous; the plugin stays dormant outside Perforce workspaces (a P4CONFIG lookup per directory) and loads its modules only when a workspace file is opened or a :P4 command runs. All state is per Neovim session. No setup() call is required: configure with `vim.g.perforated = { ... }` or `require("perforated").setup({ ... })`.'
)
add()
wrap(
  'Check your setup with `:checkhealth perforated`. `:P4 log` lists every p4 command the plugin ran, and `:P4 debug on` writes a diagnostic log.'
)

header('COMMANDS', 'perforated-commands')
wrap(
  'Everything is a subcommand of `:P4` (completion lists them). Each also has a flat alias, `:P4<sub>` (e.g. `:P4edit`), defined the first time you use it. A bang goes on the subcommand: `:P4 revert!`.'
)
add()
local commands = require('perforated.commands')
for _, name in ipairs(commands.names()) do
  local c = commands.commands[name]
  local tag = '*:P4-' .. name .. '*'
  add((':P4 %s'):format(name) .. (' '):rep(math.max(1, W - #name - 4 - #tag)) .. tag)
  wrap(c.desc, '    ')
  add()
end

header('KEYS IN PLUGIN VIEWS', 'perforated-keys')
wrap(
  'Plugin views have buffer-local keys from one action registry, which also drives the `.` action menu (right-click too), the `?` help and the key footer. Change any action\'s keys with `keys = { <id> = { "x" } }` (or `false` to remove them); `keys.p4v = false` removes the P4V-style keys (<C-d>, <C-r>, ...). The ids are listed in the `?` help of each view.'
)
local p4vc = require('perforated.p4vc').actions(ws, nil, function() end)
local views = {
  {
    'Client view (:P4)',
    'perforated-client-view',
    require('perforated.views.client')._actions(stub()),
  },
  {
    'Describe buffer (:P4 describe)',
    'perforated-describe',
    require('perforated.views.describe')._actions(stub()),
  },
  {
    'File history (:P4 filelog)',
    'perforated-history',
    vim.list_extend(
      require('perforated.views.base').nav(stub(), 'History', { expand_menu = true }),
      require('perforated.views.history').rev_actions({ ws = ws })
    ),
  },
  {
    'Annotate (:P4 annotate)',
    'perforated-annotate',
    require('perforated.views.annotate')._actions(stub()),
  },
  {
    'Time-lapse (:P4 timelapse)',
    'perforated-timelapse',
    require('perforated.views.timelapse')._actions(stub()),
  },
  {
    'Submitted changelists (:P4 changes)',
    'perforated-changes',
    require('perforated.views.changes')._actions(stub()),
  },
}
for _, v in ipairs(views) do
  add()
  add(v[1] .. (' '):rep(math.max(1, W - #v[1] - #v[2] - 2)) .. '*' .. v[2] .. '*')
  add()
  local list =
    vim.list_extend(vim.list_extend({}, v[3]), v[2] == 'perforated-changes' and {} or p4vc)
  key_table(list)
end
add()
add('Diff tab (D, :P4 diff -a)' .. (' '):rep(W - 25 - 22) .. '*perforated-diff-tab*')
add()
add('  <Tab> <S-Tab>  next / previous file (from any window of the tab)')
add('  q              close the tab')
add()
add('Quickfix lists made by the plugin' .. (' '):rep(W - 33 - 19) .. '*perforated-quickfix*')
add()
add('  d   diff the entry        x   revert        M   move to a changelist')
add('  R   resolve the entry     gr  refresh the list')

header('KEYMAPS FOR YOUR FILES', 'perforated-keymaps')
wrap(
  'Nothing is mapped in your own buffers unless you ask. Every action is a <Plug> mapping; `keymaps = "default"` installs the preset below, in Perforce buffers only (your buffer-local mappings win).'
)
add()
local km = require('perforated.keymaps')
local names = vim.tbl_keys(km.actions)
table.sort(names)
for _, n in ipairs(names) do
  add('  <Plug>(perforated-' .. n .. ')')
end
add()
add('Preset (keymaps = "default"):')
add()
local lhs = vim.tbl_keys(km.PRESET)
table.sort(lhs)
for _, k in ipairs(lhs) do
  add(('  %-14s %s'):format(k, km.PRESET[k]))
end

header('CONFIGURATION', 'perforated-config')
wrap('The defaults (every key is optional; `:checkhealth perforated` reports unknown keys):')
add()
add('>lua')
local defaults = require('perforated.config').get()
for _, l in ipairs(vim.split(vim.inspect(defaults), '\n')) do
  add('    ' .. l)
end
add('<')

header('HIGHLIGHT GROUPS', 'perforated-highlights')
wrap(
  'All are `default` links (or derived colours), so colorschemes and your config can override them:'
)
add()
local links = require('perforated.hl').LINKS
local groups = vim.tbl_keys(links)
groups[#groups + 1] = 'PerforatedUnchanged'
groups[#groups + 1] = 'PerforatedAge1..10'
table.sort(groups)
for _, g in ipairs(groups) do
  local target = links[g]
    or (g == 'PerforatedUnchanged' and 'between Normal and Comment')
    or 'annotate age gradient (annotate.gradient)'
  add(('  %-28s %s'):format(g, target))
end

header('EVENTS', 'perforated-events')
wrap('`User` autocmds you can hook (the event data is in `ev.data`):')
add()
add('  PerforatedStatus        workspace / buffer state changed (statuslines)')
add('  PerforatedChanged       files were opened, reverted, submitted, ... { ws }')
add('  PerforatedWorkspaceActivated   a workspace became active { ws }')
add('  PerforatedWorkspaceIdle        a workspace went idle (no buffers left) { ws }')
add('  PerforatedDiffOpen      a diff tab opened { tab, wins, bufs, spec, path }')
add('  PerforatedDiffClose     it closed (same data)')
add()
add(' vim:tw=78:ts=8:ft=help:norl:')

vim.fn.mkdir(vim.fs.dirname(out_path), 'p')
vim.fn.writefile(L, out_path)
print(('wrote %s (%d lines)'):format(out_path, #L))
