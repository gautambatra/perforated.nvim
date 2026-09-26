--- `:P4 diff`: side-by-side (native diff mode) in a new tab, or the user's $P4DIFF tool.

local M = {}

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
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
  local left = spec and { spec = spec } or { empty = 'opened for add' }
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

--- Side-by-side diff of any two sides in a new tab (left: old, right: new). `q` in a
--- perforated buffer (or closing either window / the tab) closes it. Fires
--- `User PerforatedDiffOpen` / `User PerforatedDiffClose` with the tab, windows and buffers.
---@param ws perforated.Workspace
---@param left perforated.DiffSide
---@param right perforated.DiffSide
---@param info { spec: string?, path: string? }?
---@return table data  event payload
function M.pair(ws, left, right, info)
  local rbuf = side_buf(ws, right)
  vim.cmd('tabnew')
  local scratch = vim.api.nvim_get_current_buf()
  local rwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rwin, rbuf)
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

  local tab = vim.api.nvim_get_current_tabpage()
  local data = {
    tab = tab,
    wins = { left = lwin, right = rwin },
    bufs = { left = lbuf, right = rbuf },
    spec = info and info.spec,
    path = info and info.path,
  }
  local function close_tab()
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, 'tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
    end
  end
  -- `q` only in plugin-owned buffers: never map keys in the user's own file.
  local user_bufs = { [left.buf or -1] = true, [right.buf or -1] = true }
  for _, b in ipairs({ lbuf, rbuf }) do
    if not user_bufs[b] then
      vim.keymap.set('n', 'q', close_tab, { buffer = b, nowait = true, desc = 'Close diff tab' })
    end
  end
  -- Closing either side (or the tab) closes the whole diff: diff mode is turned off on the
  -- user's file and PerforatedDiffClose fires exactly once.
  local aug = vim.api.nvim_create_augroup('perforated.diff.' .. tab, { clear = true })
  local closed = false
  vim.api.nvim_create_autocmd('WinClosed', {
    group = aug,
    pattern = { tostring(lwin), tostring(rwin) },
    callback = function()
      vim.schedule(function()
        if closed then
          return
        end
        closed = true
        pcall(vim.api.nvim_del_augroup_by_id, aug)
        for _, w in ipairs({ lwin, rwin }) do
          if vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_call, w, function()
              vim.cmd('diffoff')
            end)
          end
        end
        close_tab()
        require('perforated.core.events').emit('DiffClose', data)
      end)
    end,
  })
  vim.api.nvim_set_current_win(rwin)
  require('perforated.core.events').emit('DiffOpen', data)
  return data
end

return M
