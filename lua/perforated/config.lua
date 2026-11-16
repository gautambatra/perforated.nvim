---@mod perforated.config Configuration
---
--- Configuration is read lazily from `vim.g.perforated` (and/or `require('perforated').setup()`),
--- merged over the defaults on first use. `setup()` is never required.

local M = {}

---@class perforated.Config
local defaults = {
  --- p4 executable (name on $PATH or absolute path)
  p4 = 'p4',
  checkout = {
    prompt = true,
    on_write = false,
    sticky = true,
    dirs = nil,
    add_on_write = 'prompt', -- 'prompt' | 'auto' | false
    prompt_grace = 300, -- ms: keys typed right after the prompt appears are replayed as text
  },
  signs = {
    enabled = true,
    priority = 6,
    algorithm = 'myers', -- 'myers' | 'patience' | 'histogram' | 'minimal'
    max_lines = 2000, -- above this, diff on a worker thread (main thread only reads the lines)
    hard_max = 500000, -- above this, no signs
    text = { add = '+', change = '~', delete = '-', stale = '↓' },
  },
  blame_line = {
    enabled = false,
    delay = 150,
    format = 'CL {change} • {user} • {date} • {desc}',
  },
  diff = {
    tool = 'builtin',
    external_terminal = 'auto',
    --- Colours of diff views (both sides, the file panel, the headers), per window only:
    --- 'colorscheme' (yours) or 'perforated' (the plugin's own light palette, after onedark's
    --- light style); a table overrides single palette colours, e.g. { diff_add = '#d8f5dc' }.
    colors = 'colorscheme',
    --- Syntax colouring (Vim syntax, treesitter, LSP) in the diff sides. Off: plain text, so
    --- only the diff colours stand out. The buffers themselves keep it elsewhere.
    syntax = false,
    --- The diff tab prints the files after the one shown ahead of time, several in one call:
    --- up to `files` files, `max_kb` in all; a file over `file_max_kb` prints only when shown.
    --- `files = 0` turns it off.
    prefetch = { files = 10, max_kb = 2048, file_max_kb = 512 },
  },
  client_view = {
    kind = 'tab',
    --- How many of your latest submitted changelists "Recent submitted" shows (any client);
    --- `gn` there opens the full list.
    submitted_limit = 20,
    --- Changelists with more opened files than this start collapsed (0 = no limit: every one
    --- starts expanded). A file newly checked out, added or moved into one expands it anyway.
    expand_limit = 0,
    -- Paths the reconcile section scans (relative to the client root, local or depot paths;
    -- or a function(ws) returning them). Empty = the whole client. `p` in the view overrides
    -- it for the session. `mtime`: skip hashing files whose modification time matches the
    -- have list (`p4 status -m`, much faster); false hashes every file, finding edits made by
    -- tools that keep the old mtime (`cp -p`, some archive tools).
    reconcile = { paths = {}, mtime = true },
  },
  sync = { resolve_prompt = true }, -- after a sync that leaves files unresolved: offer to resolve
  complete = {
    --- `:P4` completion of depot paths and users asks p4; a <Tab> waits at most this long (ms)
    --- for an answer it doesn't have yet (a slower one shows on the next <Tab>; 0 = never wait).
    wait = 300,
  },
  shelve = {
    --- Upload threads (`--parallel=threads=N`; 0 = off). Only faster when the server allows
    --- parallel transfers (net.parallel.max > 0); otherwise p4 shelves one file at a time.
    parallel = 0,
    --- 'leave': shelve only changed files (`-a leaveunchanged`); unchanged ones stay opened
    --- and out of the upload. 'shelve' (default): every opened file.
    unchanged = 'shelve',
  },
  timelapse = {
    max_bytes = 20 * 1024 * 1024, -- larger files: use history instead
    --- Revisions annotated first; older ones load in the background (0 = all at once).
    window = 50,
    slider = true,
    info_position = 'right', -- the revision details panel: 'right' | 'bottom'
    info_width = 50, -- right-hand panel
    info_height = 12, -- bottom panel
  },
  history = { presenter = 'float', limit = 100 },
  annotate = {
    width = 36,
    integrations = false, -- -I: follow integrations to the change that really wrote the line
    history_max = 1000, -- filelog depth for descriptions (blame line) and `~` / `d` in annotate
    gradient = nil, -- { oldest, newest } hex colours; default: Comment → DiagnosticWarn
  },
  changes = { page_size = 50 },
  change = { template = nil, allow_force = false },
  merge = { tool = nil },
  --- 'auto': the first installed of telescope, fzf-lua, snacks, mini.pick, else the plugin's own
  --- list; or force one: 'telescope' | 'fzf_lua' | 'snacks' | 'mini' | 'perforated' | 'select'
  --- (vim.ui.select, e.g. for dressing.nvim).
  picker = 'auto',
  picker_mode = 'normal', -- pickers open in 'normal' mode (move with j/k, i to type) or 'insert'
  keymaps = false,
  keys = { p4v = true },
  commands = { aliases = true },
  qf = { open = true },
  startup_check = true,
  poll = {
    interval = 30,
    focus_throttle = 2,
    bufenter_throttle = 60,
    bufenter_max_age = 600,
    reuse = 5,
  },
  toast = { timeout = 3000, backend = 'float', history = 50 },
  statusline = {
    -- File part. Tokens: {client} {action} (icon, action@CL) {change} {modified} (marker when
    -- the file differs from its have revision) {rev} (#have, or "not in depot") {head}
    -- {stale} {unresolved} {diff} (+added ~changed -removed lines). Or a function(dict).
    format = '{client} {action} {modified} {rev} {stale} {unresolved}',
    stale = '↓',
    unresolved = '!',
    offline = '⊘',
  },
  icons = { provider = 'auto', style = 'auto', glyphs = {} },
  runner = { concurrency = 4, timeout = 10000, background_timeout = 5000 },
  cache = { content_mb = 32 },
  log = { size = 500 },
  --- Debug log file (also: env PERFORATED_DEBUG=1|trace, or :P4 debug on).
  debug = { enabled = false, level = 'debug', file = nil, max_kb = 5120 },
  swarm = { url = nil },
  --- Experimental: Perforce actions as LSP code actions (`gra`) in Perforce buffers
  lsp = { enabled = false },
}

local user_opts = nil ---@type table?
local merged = nil ---@type perforated.Config?

--- Merge user options (from `setup()`); takes effect immediately.
---@param opts table?
function M.set(opts)
  user_opts = vim.tbl_deep_extend('force', user_opts or {}, opts or {})
  merged = nil
end

---@return perforated.Config
function M.get()
  if not merged then
    local g = vim.g.perforated
    merged = vim.tbl_deep_extend(
      'force',
      vim.deepcopy(defaults),
      type(g) == 'table' and g or {},
      user_opts or {}
    )
  end
  return merged
end

--- Force re-reading `vim.g.perforated` on next `get()` (e.g. after the user changed it).
function M.reload()
  merged = nil
end

--- Test helper: forget setup() options.
function M._reset()
  user_opts, merged = nil, nil
end

--- Paths of user-provided keys that don't exist in the defaults. Used by :checkhealth,
--- so typos are reported without costing anything on the startup path.
---@return string[]
function M.unknown_keys()
  local out = {}
  local function walk(user, def, prefix)
    for k, v in pairs(user) do
      local path = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
      if def[k] == nil then
        -- Keys whose default is nil (e.g. checkout.dirs) are valid; `keys.<action>` overrides
        -- any action's keys.
        if not M._nil_ok[path] and not path:match('^keys%.') then
          out[#out + 1] = path
        end
      elseif
        type(v) == 'table'
        and type(def[k]) == 'table'
        and not vim.islist(def[k])
        and next(def[k]) ~= nil -- empty-table defaults (icons.glyphs) accept any keys
      then
        walk(v, def[k], path)
      end
    end
  end
  local g = vim.g.perforated
  local merged_user = vim.tbl_deep_extend('force', type(g) == 'table' and g or {}, user_opts or {})
  local colors = (merged_user.diff or {}).colors
  if type(colors) == 'table' then
    local palette = require('perforated.diff.look').PALETTE
    for k in pairs(colors) do
      if palette[k] == nil then
        out[#out + 1] = 'diff.colors.' .. tostring(k)
      end
    end
  elseif colors ~= nil and colors ~= 'colorscheme' and colors ~= 'perforated' then
    out[#out + 1] = ('diff.colors = %q'):format(tostring(colors))
  end
  walk(merged_user, defaults, '')
  table.sort(out)
  return out
end

-- Keys whose default is nil but are valid.
M._nil_ok = {
  ['checkout.dirs'] = true,
  ['change.template'] = true,
  ['merge.tool'] = true,
  ['swarm.url'] = true,
  ['debug.file'] = true,
}

M.defaults = defaults

return M
