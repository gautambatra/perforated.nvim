---@mod perforated.config Configuration
---
--- Configuration is read lazily from `vim.g.perforated` (and/or `require('perforated').setup()`),
--- merged over the defaults on first use. `setup()` is never required.

local M = {}

---@class perforated.Config
local defaults = {
  --- p4 executable (name on $PATH or absolute path)
  p4 = 'p4',
  --- p4vc executable (revision graph, P4V time-lapse, stream graph), when installed
  p4vc = 'p4vc',
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
    base = 'have',
    priority = 6,
    algorithm = 'myers', -- 'myers' | 'patience' | 'histogram' | 'minimal'
    max_lines = 2000, -- above this, diff on a worker thread (main thread only reads the lines)
    hard_max = 500000, -- above this, no signs
    text = { add = '▎', change = '▎', delete = '▁', stale = '↓' },
  },
  blame_line = {
    enabled = false,
    delay = 150,
    format = 'CL {change} • {user} • {date} • {desc}',
  },
  diff = { layout = 'tab', tool = 'builtin', external_terminal = 'auto' },
  client_view = {
    kind = 'tab',
    sections = { 'pending', 'unresolved', 'reconcile', 'submitted' },
    submitted_limit = 20,
    -- Paths the reconcile section scans (relative to the client root, local or depot paths;
    -- or a function(ws) returning them). Empty = the whole client. `p` in the view overrides
    -- it for the session.
    reconcile = { paths = {} },
  },
  sync = { resolve_prompt = true }, -- after a sync that leaves files unresolved: offer to resolve
  timelapse = {
    max_bytes = 20 * 1024 * 1024, -- larger files: use history instead
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
  changes = { page_size = 50, scope = 'client' },
  change = { template = nil, allow_force = false },
  merge = { tool = nil },
  picker = 'auto',
  keymaps = false,
  keys = { p4v = true },
  commands = { aliases = true },
  qf = { open = true, loclist_for_file_scoped = true },
  startup_check = true,
  poll = { interval = 300, focus_throttle = 30, bufenter_throttle = 60 },
  toast = { timeout = 8000, backend = 'float', history = 50 },
  statusline = { stale = '↓', unresolved = '!', offline = '⊘' },
  icons = { provider = 'auto', style = 'auto', glyphs = {} },
  runner = { concurrency = 4, timeout = 10000, background_timeout = 5000 },
  cache = { content_mb = 32 },
  log = { size = 500 },
  --- Debug log file (also: env PERFORATED_DEBUG=1|trace, or :P4 debug on).
  debug = { enabled = false, level = 'debug', file = nil, max_kb = 5120 },
  swarm = { url = nil },
  --- Experimental: Perforce actions as LSP code actions (`gra`) in Perforce buffers
  lsp = { enabled = false },
  notify = 'minimal',
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
  walk(vim.tbl_deep_extend('force', type(g) == 'table' and g or {}, user_opts or {}), defaults, '')
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
