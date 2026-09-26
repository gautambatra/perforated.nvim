--- :checkhealth perforated

local M = {}

local h = vim.health

local function sys(argv, opts)
  local ok, obj = pcall(vim.system, argv, vim.tbl_extend('force', { text = true }, opts or {}))
  if not ok then
    return { code = -1, stdout = '', stderr = tostring(obj) }
  end
  return obj:wait(opts and opts.timeout or 5000)
end

local function check_nvim()
  h.start('Neovim')
  if vim.fn.has('nvim-0.11') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.11+ is required')
  end
end

local function check_p4()
  h.start('p4 client')
  local env = require('perforated.core.env')
  local bin = env.p4_bin()
  if not bin then
    h.error(
      ('p4 executable %q not found'):format(require('perforated.config').get().p4),
      { 'Install the Helix Core CLI (p4) or set vim.g.perforated = { p4 = "/path/to/p4" }' }
    )
    return nil
  end
  local r = sys({ bin, '-V' })
  local rev = (r.stdout or ''):match('Rev%. (%S+)')
  h.ok(('p4: %s (%s)'):format(bin, rev or 'unknown version'))
  local year = tonumber((rev or ''):match('/(%d%d%d%d)%.%d'))
  if year and year < 2021 then
    h.warn('p4 client older than 2021.2 may not support -Mj JSON output; text fallback is limited')
  end
  return bin
end

local function check_env()
  h.start('Perforce environment')
  local env = require('perforated.core.env')
  local gate = require('perforated.gate')
  local name = env.config_name()
  if name then
    h.ok('P4CONFIG = ' .. name)
  else
    h.info('P4CONFIG not set (workspace detection uses P4CLIENT from the environment, if set)')
  end
  local enviro = env.enviro_path()
  if vim.uv.fs_stat(enviro) then
    h.info('P4ENVIRO file: ' .. enviro)
  end
  local p4diff, p4merge = env.get('P4DIFF'), env.get('P4MERGE')
  h.info('P4DIFF (external diff tool): ' .. (p4diff or 'not set in environment/P4ENVIRO'))
  h.info('P4MERGE (merge tool): ' .. (p4merge or 'not set in environment/P4ENVIRO'))
  local p4vc = require('perforated.p4vc').bin()
  if p4vc then
    h.ok('p4vc: ' .. vim.fn.exepath(p4vc) .. ' (revision graph, P4V time-lapse, stream graph)')
  else
    h.info('p4vc not found: the revision graph / P4V time-lapse / stream graph actions are hidden')
  end

  -- Targets: every active workspace (checked from its own anchor), else the workspace of
  -- Neovim's cwd. :checkhealth runs in its own buffer, so the current buffer is no guide.
  local targets = {}
  local wsmod = package.loaded['perforated.core.workspace']
  for _, ws in ipairs(wsmod and wsmod.list() or {}) do
    targets[#targets + 1] = { dir = ws.anchor, label = ws.key }
    h.ok(
      ('Active workspace: %s (%d buffers%s)'):format(
        ws.key,
        vim.tbl_count(ws.buffers),
        ws.idle and ', idle' or ''
      )
    )
  end
  if #targets == 0 then
    local cwd = vim.uv.cwd() or '.'
    local hit = gate and gate.lookup(cwd)
    if hit then
      h.ok(('Workspace anchor for %s: %s (%s)'):format(cwd, hit.anchor, hit.file))
      targets[1] = { dir = hit.anchor, label = hit.anchor }
    elseif env.has_env_client() then
      h.info('Environment-only setup (P4CLIENT set, no P4CONFIG file)')
      targets[1] = { dir = cwd, label = cwd }
    else
      h.info('Not inside a Perforce workspace: ' .. cwd, {
        'The plugin stays dormant here. Connection-only commands (:P4 describe, …) still work.',
      })
      targets[1] = { dir = cwd, label = cwd, optional = true }
    end
  end
  return targets
end

local function check_server(bin, target)
  local cwd = target.dir
  h.start('Server (from ' .. target.label .. ')')
  local fail = target.optional and h.warn or h.error
  local t0 = vim.uv.hrtime()
  local r = sys({ bin, '-Mj', '-ztag', 'info' }, {
    cwd = cwd,
    env = require('perforated.core.env').child_env(cwd, 'internal'),
    clear_env = true,
    timeout = 5000,
  })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if r.code ~= 0 then
    fail(
      ('p4 info failed (%s)'):format(vim.trim((r.stderr or '') .. (r.stdout or ''))),
      { 'Check P4PORT / network; :P4 log shows every command the plugin ran' }
    )
    return
  end
  local rec = require('perforated.core.parse').jsonl(r.stdout).records[1] or {}
  h.ok(('Server %s reachable in %.0f ms'):format(rec.serverVersion or '?', ms))
  if ms > 200 then
    h.warn('Round-trip is slow; background refreshes will be less frequent than they could be')
  end
  if rec.clientName and rec.clientName ~= '*unknown*' then
    h.ok(
      ('Client %s, root %s, user %s'):format(
        rec.clientName,
        rec.clientRoot or '?',
        rec.userName or '?'
      )
    )
  else
    h.info('No client workspace resolved from ' .. cwd)
  end
  local login = sys({ bin, '-Mj', '-ztag', 'login', '-s' }, {
    cwd = cwd,
    env = require('perforated.core.env').child_env(cwd, 'internal'),
    clear_env = true,
    timeout = 5000,
  })
  local parsed = require('perforated.core.parse').jsonl(login.stdout or '')
  if login.code == 0 and #parsed.errors == 0 then
    h.ok('Logged in (or no password required)')
  else
    h.warn(
      'Not logged in: ' .. (parsed.errors[1] or vim.trim(login.stderr or '')),
      { 'Run :P4 login' }
    )
  end
end

local function check_config()
  h.start('Configuration')
  local unknown = require('perforated.config').unknown_keys()
  if #unknown == 0 then
    h.ok('No unknown configuration keys')
  else
    for _, k in ipairs(unknown) do
      h.warn('Unknown configuration key: ' .. k)
    end
  end
end

local function check_debug()
  h.start('Debug log')
  local dbg = package.loaded['perforated.core.debug']
  if dbg and dbg.enabled then
    h.ok('Debug logging is ON → ' .. dbg.file())
  else
    local default = require('perforated.core.debug').default_file()
    h.info(
      'Debug logging is off. Enable: :P4 debug on | PERFORATED_DEBUG=1 | debug = { enabled = true }'
    )
    h.info('Log file: ' .. default)
  end
end

local function check_integrations()
  h.start('Optional integrations')
  for _, mod in ipairs({
    'telescope',
    'fzf-lua',
    'snacks',
    'mini.pick',
    'mini.icons',
    'nvim-web-devicons',
    'lualine',
    'fidget',
  }) do
    local found = pcall(require, mod)
    h.info(('%-18s %s'):format(mod, found and 'found' or 'not installed'))
  end
end

local function check_terminal()
  h.start('Terminal')
  if vim.env.TMUX then
    local r = sys({ 'tmux', 'show', '-gv', 'focus-events' })
    if vim.trim(r.stdout or '') == 'on' then
      h.ok('tmux focus-events on (stale checks pause while Neovim is in a background pane)')
    else
      h.warn('tmux focus-events is off', {
        "Add `set -g focus-events on` to tmux.conf so background panes don't poll and notices wait for you",
      })
    end
  end
  local term = vim.env.TERM_PROGRAM or vim.env.TERM or ''
  local csi_u = term:find('kitty')
    or term:find('WezTerm')
    or term:find('ghostty')
    or term:find('foot')
  if csi_u then
    h.ok('Terminal likely supports Ctrl+Shift/Ctrl+digit keys (P4V layer): ' .. term)
  else
    h.info(
      'Ctrl+Shift+<key> P4V shortcuts may not be distinguishable in '
        .. term
        .. '; vim-style fallbacks always work'
    )
  end
end

function M.check()
  check_nvim()
  local bin = check_p4()
  local targets = check_env()
  if bin then
    for _, t in ipairs(targets) do
      check_server(bin, t)
    end
  end
  check_config()
  check_debug()
  check_integrations()
  check_terminal()
end

return M
