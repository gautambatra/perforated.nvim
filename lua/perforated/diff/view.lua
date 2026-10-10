--- `:P4 diff`: side-by-side (native diff mode) in a new tab, or the user's $P4DIFF tool.

local M = {}

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Resolve a user revision argument against a buffer's fstat record.
---   nil → the diff base (#have; move/add: moved-from file; add: nothing)
---   '#3' '#head' '#have' '@1234' '@=1234' 'prev' (= #have-1)
---@param rec table
---@param rev string?
---@return string|false|nil spec  false = empty base (file opened for add)
function M.resolve_spec(rec, rev)
  if not rev or rev == '' then
    if rec.action then
      return require('perforated.p4').base_spec(rec) or false
    end
    return rec.depotFile .. '#' .. (rec.haveRev or 'head')
  end
  if rev == 'prev' then
    local have = tonumber(rec.haveRev)
    if not have or have <= 1 then
      return nil
    end
    return rec.depotFile .. '#' .. (have - 1)
  end
  if rev:match('^%d+$') then
    rev = '#' .. rev
  end
  if not rev:match('^[#@]') then
    return nil
  end
  return rec.depotFile .. rev
end

local GUI = {
  p4merge = true,
  meld = true,
  bcompare = true,
  bcomp = true,
  kdiff3 = true,
  opendiff = true,
  code = true,
  winmergeu = true,
  diffmerge = true,
  tkdiff = true,
  xxdiff = true,
  gvimdiff = true,
  kompare = true,
  diffuse = true,
  araxis = true,
  compare = true,
  ['p4vc'] = true,
}

M.GUI = GUI

--- Open the user's $P4DIFF tool on (depot revision, workspace file).
---
--- p4 itself can't be relied on for this: `p4 diff` only launches P4DIFF when the files differ
--- and `p4 diff2` ignores P4DIFF. So we follow p4's convention ourselves: `$P4DIFF old new`,
--- with the user's untouched environment, run through `sh` so tool arguments work
--- (e.g. P4DIFF="code --wait --diff"). The depot copy is a temp file named after the file.
---@param ws perforated.Workspace
---@param path string
---@param spec string|false  depot revision (false = empty, file opened for add)
function M.external(ws, path, spec)
  local bin = require('perforated.core.env').p4_bin() or 'p4'
  local cwd = ws:cwd()
  vim.system(
    { bin, 'set', '-q', 'P4DIFF' },
    { cwd = cwd, env = { PWD = cwd }, text = true },
    function(r)
      vim.schedule(function()
        local tool = vim.trim((r.stdout or ''):match('P4DIFF=(.*)') or '')
        if tool == '' then
          return notify(
            'P4DIFF is not set (environment, P4CONFIG or P4ENVIRO)',
            vim.log.levels.WARN
          )
        end
        local function launch(lines)
          local dir = vim.fn.tempname()
          vim.fn.mkdir(dir, 'p')
          local label = spec and (vim.fs.basename(spec):gsub('[#@=]', '_')) or 'empty'
          local old = dir .. '/' .. label
          vim.fn.writefile(lines, old, 'b')
          local argv = { 'sh', '-c', tool .. ' "$@"', 'p4diff', old, path }
          local function cleanup()
            vim.schedule(function()
              vim.fn.delete(dir, 'rf')
            end)
          end
          local mode = require('perforated.config').get().diff.external_terminal
          local exe = vim.fs.basename(vim.split(tool, '%s+')[1]):lower():gsub('%.exe$', '')
          local terminal = mode == true or (mode == 'auto' and not GUI[exe])
          if terminal then
            vim.cmd('tabnew')
            vim.fn.jobstart(
              argv,
              { term = true, cwd = cwd, env = { PWD = cwd }, on_exit = cleanup }
            )
            vim.cmd('startinsert')
          else
            vim.system(argv, { cwd = cwd, env = { PWD = cwd }, detach = true }, function(res)
              cleanup()
              if res.code ~= 0 and res.code ~= 1 then -- diff tools exit 1 for "files differ"
                vim.schedule(function()
                  notify(
                    'external diff failed: ' .. vim.trim(res.stderr or ''),
                    vim.log.levels.ERROR
                  )
                end)
              end
            end)
          end
        end
        if not spec then
          return launch({})
        end
        require('perforated.p4').print(ws, spec, {}, function(lines, err)
          if not lines then
            return notify('could not fetch ' .. spec .. ': ' .. tostring(err), vim.log.levels.ERROR)
          end
          launch(lines)
        end)
      end)
    end
  )
end

--- Side-by-side diff of a buffer against a depot revision, in a new tab.
---@param buf integer
---@param rev string?
---@param opts { external: boolean? }?
function M.open(buf, rev, opts)
  local st = require('perforated.buffer').get(buf)
  if not st or not st.rec then
    return notify('not a Perforce depot file (or status not known yet)', vim.log.levels.WARN)
  end
  local spec = M.resolve_spec(st.rec, rev)
  if spec == nil then
    return notify('invalid revision: ' .. tostring(rev), vim.log.levels.ERROR)
  end
  local ext = (opts and opts.external) or require('perforated.config').get().diff.tool == 'external'
  local have = st.rec.haveRev and (st.rec.depotFile .. '#' .. st.rec.haveRev)
  local left = spec and { spec = spec, label = spec == have and 'have' or nil }
    or { empty = 'opened for add' }
  require('perforated.same').or_open(st.ws, left, { buf = buf }, function()
    if ext then
      return M.external(st.ws, st.path, spec)
    end
    M.pair(st.ws, left, { buf = buf }, { spec = spec or nil, path = st.path })
  end)
end

---@class perforated.DiffSide
---@field buf integer?     an existing buffer (e.g. the user's file)
---@field spec string?     a depot revision (perforated:// buffer, loaded asynchronously)
---@field empty string?    an empty placeholder (label shown in the buffer name)
---@field label string?    what the side is, for its header (default: from the spec or path)

--- Header text for a side: `{ path, what }`, e.g. `{ '//depot/a.c', '@=12 (shelved)' }`,
--- `{ 'src/a.c', '(workspace)' }`, `{ '//depot/a.c', '#3 (have)' }`.
---@param ws perforated.Workspace
---@param side perforated.DiffSide
---@return string path
---@return string what
function M.side_label(ws, side)
  local function kind(default)
    local k = side.label or default
    return k and ('(' .. k .. ')') or nil
  end
  if side.spec then
    local path, rev = side.spec:match('^(.-)([#@].*)$')
    path, rev = path or side.spec, rev or ''
    local default = rev:match('^@=') and 'shelved' or (rev == '#head' and 'head') or nil
    local k = kind(default)
    return path, k and (rev .. ' ' .. k) or rev
  end
  if side.buf then
    local name = vim.api.nvim_buf_get_name(side.buf)
    local root = ws.root
    if root and name:sub(1, #root + 1) == root .. '/' then
      name = name:sub(#root + 2)
    else
      name = vim.fn.fnamemodify(name, ':~:.')
    end
    return name, kind('workspace')
  end
  return '', kind(side.empty or 'empty')
end

--- Show a side's header in a diff window's winbar.
---@param win integer
---@param ws perforated.Workspace
---@param side perforated.DiffSide
function M.header(win, ws, side)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local path, what = M.side_label(ws, side)
  local function esc(str)
    return (str:gsub('%%', '%%%%'))
  end
  vim.wo[win][0].winbar = ('%%#PerforatedDiffHeader# %s %%#PerforatedDiffHeaderKind#%s%%*'):format(
    esc(path),
    esc(what)
  )
end

local function p4v_keys()
  return (require('perforated.config').get().keys or {}).p4v ~= false
end

--- Ctrl+1 / Ctrl+2: previous / next change (Vim's `[c` / `]c`, which keep working), in the
--- diff sides of one tab only (P4V-style keys: not with `keys.p4v = false`). Needs a terminal
--- that reports Ctrl+digit (CSI-u).
---@param tab integer
---@param buf integer
function M.change_keys(tab, buf)
  if not p4v_keys() then
    return
  end
  M.tab_key(tab, buf, '<C-1>', function()
    vim.cmd('normal! ' .. vim.v.count1 .. '[c')
  end, 'Previous change')
  M.tab_key(tab, buf, '<C-2>', function()
    vim.cmd('normal! ' .. vim.v.count1 .. ']c')
  end, 'Next change')
end

--- A diff side shows no sign column: the diff colours already mark every change, and gutter
--- signs (the plugin's hunk signs, diagnostics) would only repeat them and take width.
---@param win integer
function M.side_win(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win][0].signcolumn = 'no'
  end
end

--- Drop what the plugin set on a diff window (its header, the hidden sign column) before it
--- shows another buffer or closes: Neovim remembers a window's local options per buffer, and
--- the user's file must not take them along.
---@param win integer
function M.clear_header(win)
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('set winbar< signcolumn<')
    end)
  end
end

-- Keys that act only inside one diff tab: buf → lhs → { [tab] = fn }. One buffer can be in
-- several diff tabs (or shown elsewhere), and the user's own file keeps its keys everywhere
-- else: outside a diff tab the key does what it would have done.
local scoped = {}

--- Map `lhs` in `buf` to `fn` while the current tab is `tab`. A buffer-local mapping the user
--- already has wins.
---@param tab integer
---@param buf integer
---@param lhs string
---@param fn function
---@param desc string
function M.tab_key(tab, buf, lhs, fn, desc)
  local by = scoped[buf] or {}
  if not by[lhs] then
    local mine = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, 'n', false, true).buffer == 1
    end)
    if mine then
      return
    end
    by[lhs] = {}
    vim.keymap.set('n', lhs, function()
      local tabs = scoped[buf] and scoped[buf][lhs]
      local handler = tabs and tabs[vim.api.nvim_get_current_tabpage()]
      if handler then
        return handler()
      end
      local count = vim.v.count > 0 and tostring(vim.v.count) or ''
      vim.api.nvim_feedkeys(count .. vim.keycode(lhs), 'n', false)
    end, { buffer = buf, nowait = true, desc = desc })
  end
  scoped[buf] = by
  by[lhs][tab] = fn
end

--- Forget a tab's keys in these buffers (deleting mappings no other tab uses).
---@param tab integer
---@param bufs integer[]
function M.tab_keys_drop(tab, bufs)
  for _, b in ipairs(bufs) do
    local by = scoped[b]
    for lhs, tabs in pairs(by or {}) do
      tabs[tab] = nil
      if next(tabs) == nil then
        by[lhs] = nil
        if vim.api.nvim_buf_is_valid(b) then
          pcall(vim.keymap.del, 'n', lhs, { buffer = b })
        end
      end
    end
    if by and next(by) == nil then
      scoped[b] = nil
    end
  end
end

--- Close a diff tab; the last tab can't be closed, so there the windows go back to one.
---@param tab integer
function M.close_tab(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
  else
    pcall(vim.cmd, 'only')
  end
end

---@param ws perforated.Workspace
---@param side perforated.DiffSide
---@return integer buf
local function side_buf(ws, side)
  if side.buf then
    return side.buf
  end
  if side.spec then
    return require('perforated.uri').buffer(ws, side.spec)
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'wipe'
  pcall(vim.api.nvim_buf_set_name, b, ('perforated://null (%s)'):format(side.empty or 'empty'))
  vim.bo[b].modifiable = false
  return b
end
M.side_buf = side_buf

--- Line up the two sides of a diff. Scroll-bound windows only follow a window that scrolls
--- itself, so a side shown with a remembered position (the user's file, read further down) or
--- filled later (a revision arriving from p4) would stay out of line until the cursor went
--- there. `ref` is the side the other one follows; with `first_change` it moves to the first
--- change first (diff tab: each file opens at its first change).
--- A revision still on its way from p4 is empty, so against it every line is a change: the
--- window remembers it wants the first change (`w:perforated_first_change`) and the fetch
--- that fills the other side aligns again with it (once).
---@param ref integer   window
---@param other integer window
---@param first_change boolean?
function M.align(ref, other, first_change)
  if not (vim.api.nvim_win_is_valid(ref) and vim.api.nvim_win_is_valid(other)) then
    return
  end
  vim.w[ref].perforated_first_change = first_change or nil
  local rbuf, obuf = vim.api.nvim_win_get_buf(ref), vim.api.nvim_win_get_buf(other)
  -- The first change from our own diff of the two buffers: `]c` depends on when Neovim last
  -- recomputed its diff (on 0.11 not yet, right after a revision was filled in).
  local first
  if first_change then
    local rn, on = vim.api.nvim_buf_line_count(rbuf), vim.api.nvim_buf_line_count(obuf)
    if rn <= 20000 and on <= 20000 then
      local h = require('perforated.diff.engine').hunks(
        vim.api.nvim_buf_get_lines(obuf, 0, -1, false),
        vim.api.nvim_buf_get_lines(rbuf, 0, -1, false)
      )[1]
      first = h and { math.max(h.b_start, 1), math.max(h.a_start, 1) } or { 1, 1 }
    end
  end
  pcall(vim.api.nvim_win_call, ref, function()
    if first then
      vim.api.nvim_win_set_cursor(0, { first[1], 0 })
    elseif first_change then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      if vim.fn.diff_hlID(1, 1) == 0 and vim.fn.diff_filler(1) == 0 then
        vim.cmd('silent! normal! ]c')
      end
    end
    vim.cmd('syncbind')
  end)
  -- The other side's cursor: its own first change, else the same distance below its (now
  -- aligned) top line. Cursorbind keeps them together from the next movement on.
  local line
  if first then
    line = first[2]
  else
    local offset = vim.api.nvim_win_get_cursor(ref)[1] - vim.fn.line('w0', ref)
    line = vim.fn.line('w0', other) + offset
  end
  line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(obuf)))
  pcall(vim.api.nvim_win_set_cursor, other, { line, 0 })
end

--- Turn diff mode on in windows, tolerating user OptionSet autocmds that throw.
---@param wins integer[]
function M.diffthis(wins)
  local errs = {}
  for _, w in ipairs(wins) do
    local ok, err = pcall(vim.api.nvim_win_call, w, function()
      vim.cmd('diffthis')
    end)
    if not ok then
      errs[#errs + 1] = tostring(err)
    end
  end
  if #errs > 0 then
    local first = errs[1]:match('(E%d+:[^\n]*)') or errs[1]:match('[^\n]*')
    require('perforated.core.debug').warn('diff', 'autocmd error during diffthis: %s', errs[1])
    notify(
      'an OptionSet autocmd in your config failed during :diffthis: ' .. first,
      vim.log.levels.WARN
    )
  end
end

--- Side-by-side diff of any two sides in a new tab (left: old, right: new), each with a
--- header (winbar). `q` in either side, or closing either window or the tab, closes it. Fires
--- `User PerforatedDiffOpen` / `User PerforatedDiffClose` with the tab, windows and buffers.
---@param ws perforated.Workspace
---@param left perforated.DiffSide
---@param right perforated.DiffSide
---@param info { spec: string?, path: string? }?
---@return table data  event payload
function M.pair(ws, left, right, info)
  local rbuf = side_buf(ws, right)
  -- Diffing the file you're in: keep your place in it (a new window would take the buffer's
  -- last remembered position, possibly from another window).
  local from_view
  if vim.api.nvim_get_current_buf() == rbuf then
    from_view = vim.fn.winsaveview()
  end
  vim.cmd('tabnew')
  local scratch = vim.api.nvim_get_current_buf()
  local rwin = vim.api.nvim_get_current_win()
  require('perforated.views.base').code_win(rwin) -- the left side (vnew) copies it
  vim.api.nvim_win_set_buf(rwin, rbuf)
  if from_view then
    vim.fn.winrestview(from_view)
  end
  if vim.api.nvim_buf_is_valid(scratch) and scratch ~= rbuf then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  vim.cmd('leftabove vnew')
  local lwin = vim.api.nvim_get_current_win()
  local placeholder = vim.api.nvim_get_current_buf()
  local lbuf = side_buf(ws, left)
  vim.api.nvim_win_set_buf(lwin, lbuf)
  if placeholder ~= lbuf and vim.api.nvim_buf_is_valid(placeholder) then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  M.diffthis({ lwin, rwin })
  require('perforated.diff.look').apply({ [lwin] = 'code', [rwin] = 'code' })
  -- The revision follows the user's place in their file — again once the diff has been drawn
  -- (diff folds settle on the first redraw and can scroll the window).
  M.align(rwin, lwin)
  vim.schedule(function()
    M.align(rwin, lwin)
  end)

  M.header(lwin, ws, left)
  M.header(rwin, ws, right)
  M.side_win(lwin)
  M.side_win(rwin)

  local tab = vim.api.nvim_get_current_tabpage()
  local data = {
    tab = tab,
    wins = { left = lwin, right = rwin },
    bufs = { left = lbuf, right = rbuf },
    spec = info and info.spec,
    path = info and info.path,
  }
  local function close()
    M.close_tab(tab)
  end
  -- `q` in both sides, the user's file included, but only inside this tab.
  for _, b in ipairs({ lbuf, rbuf }) do
    M.tab_key(tab, b, 'q', close, 'Close diff tab')
    M.change_keys(tab, b)
  end
  -- Closing either side (or the tab) closes the whole diff: diff mode is turned off on the
  -- user's file and PerforatedDiffClose fires exactly once.
  local aug = vim.api.nvim_create_augroup('perforated.diff.' .. tab, { clear = true })
  local closed = false
  vim.api.nvim_create_autocmd('WinClosed', {
    group = aug,
    pattern = { tostring(lwin), tostring(rwin) },
    callback = function()
      if closed then
        return
      end
      closed = true
      pcall(vim.api.nvim_del_augroup_by_id, aug)
      -- Now, while both windows exist: the one being closed saves its options for its buffer.
      M.clear_header(lwin)
      M.clear_header(rwin)
      vim.schedule(function()
        M.tab_keys_drop(tab, { lbuf, rbuf })
        for _, w in ipairs({ lwin, rwin }) do
          if vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_call, w, function()
              vim.cmd('diffoff')
            end)
          end
        end
        close()
        require('perforated.core.events').emit('DiffClose', data)
      end)
    end,
  })
  vim.api.nvim_set_current_win(rwin)
  require('perforated.core.events').emit('DiffOpen', data)
  return data
end

return M
