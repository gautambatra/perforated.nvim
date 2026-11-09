--- The edit/add/revert operations (`:P4 edit`, the check-out menu, add on write, revert).
--- Loaded on first use: `checkout.lua` forwards to them, so they aren't loaded with every
--- workspace.

local p4 = require('perforated.p4')
local dbg = require('perforated.core.debug')
local co = require('perforated.checkout')

local bufs_for, changed, state, tree = co.bufs_for, co.changed, co._state, co._tree

local M = {}

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Report the outcome of a file command: short message on success, errors (with file names)
--- as a notification — lists go to quickfix once M2's qf sink exists.
---@param verb string
---@param res perforated.RunResult
---@param count integer
local function report(verb, res, count)
  if res.stopped then
    return -- `jobs.run` already said so
  end
  dbg.log(
    (#res.errors > 0 or not res.ok) and 'warn' or 'info',
    'checkout',
    '%s: %d file(s) ok=%s errors=%s warnings=%s',
    verb,
    count,
    tostring(res.ok),
    table.concat(res.errors, ' | '),
    table.concat(res.warnings, ' | ')
  )
  if #res.errors > 0 then
    local head = res.errors[1]
    if #res.errors > 1 then
      head = head .. (' (+%d more; see :P4 log)'):format(#res.errors - 1)
    end
    notify(('%s failed: %s'):format(verb, head), vim.log.levels.ERROR)
  elseif not res.ok then
    notify(
      ('%s failed: %s'):format(
        verb,
        vim.trim(res.stderr ~= '' and res.stderr or ('p4 exited with code ' .. res.code))
      ),
      vim.log.levels.ERROR
    )
  else
    local warn = res.warnings[1]
    notify(
      ('%s: %d file(s)%s'):format(verb, count, warn and (' — ' .. warn) or ''),
      warn and vim.log.levels.WARN or nil
    )
  end
end

M.report = report

--- Make read-only files writable right away (what `p4 edit` is about to do anyway), so a
--- `:w` issued before the server answers passes Neovim's permission check (E505), which runs
--- before any write autocmd. Returns a function restoring the original modes, except for the
--- paths in `keep` (a set of paths p4 did open).
---@param paths string[]
---@return fun(keep: table<string, true>?)
function M.optimistic_writable(paths)
  local restore = {}
  for _, p in ipairs(paths) do
    local st = vim.uv.fs_stat(p)
    if st and vim.fn.filewritable(p) == 0 then
      if vim.uv.fs_chmod(p, bit.bor(st.mode, tonumber('200', 8))) then
        restore[p] = st.mode
      end
    end
  end
  return function(keep)
    for p, mode in pairs(restore) do
      if not (keep and keep[p]) then
        vim.uv.fs_chmod(p, mode)
      end
    end
  end
end

--- "Checking out a.c…", for the pop-up in the middle of the screen while p4 works (it can take
--- a moment, and nothing else shows that something is happening).
---@param fmt_one string   e.g. 'Checking out %s…'
---@param fmt_many string  e.g. 'Checking out %d files…'
---@param paths string[]
---@return string
local function busy(fmt_one, fmt_many, paths)
  local dir = #paths == 1 and tree(paths[1])
  return dir and fmt_one:format(vim.fn.fnamemodify(dir, ':t') .. '/...')
    or #paths == 1 and fmt_one:format(vim.fn.fnamemodify(paths[1], ':t'))
    or fmt_many:format(#paths)
end

--- p4 edit files into a changelist (nil/'default' = default CL).
---@param ws perforated.Workspace
---@param paths string[]
---@param cl string?
---@param cb fun(ok: boolean, res: perforated.RunResult)?
function M.edit(ws, paths, cl, cb)
  local bufs = bufs_for(ws, paths)
  for _, b in ipairs(bufs) do
    state(b).pending = true
  end
  local concrete = vim.tbl_filter(function(p)
    return not tree(p)
  end, paths)
  for _, b in ipairs(bufs) do
    local st = require('perforated.buffer').get(b)
    concrete[#concrete + 1] = st and st.path or nil
  end
  local restore = M.optimistic_writable(concrete)
  p4.edit(ws, paths, cl, function(res)
    for _, b in ipairs(bufs) do
      state(b).pending = false
    end
    local ok = #res.records > 0 and #res.errors == 0 and not res.stopped
    local keep = {}
    if not ok then
      -- Only the files p4 didn't open go back to read-only: after a partial failure the
      -- opened ones must stay writable.
      local opened = {}
      for _, r in ipairs(res.records) do
        if r.clientFile then
          opened[vim.fs.normalize(r.clientFile)] = true
        end
      end
      dbg.warn('checkout', 'edit failed; restoring file modes for unopened path(s)')
      for _, p in ipairs(concrete) do
        if opened[vim.fs.normalize(p)] then
          keep[p] = true
        end
      end
      restore(keep)
    end
    -- A write that stopped waiting made its file read-only again: opened, it is writable.
    for _, b in ipairs(bufs) do
      local c = state(b)
      local st = require('perforated.buffer').get(b)
      if c.refused_mode and st and (ok or keep[st.path]) then
        vim.uv.fs_chmod(st.path, c.refused_mode)
      end
      c.refused_mode = nil
    end
    report('edit', res, #res.records)
    changed(ws, { files = paths })
    for _, b in ipairs(bufs) do
      if ok and vim.api.nvim_buf_is_valid(b) then
        vim.bo[b].readonly = false
      end
      require('perforated.buffer').refresh(b)
    end
    if cb then
      cb(ok, res)
    end
  end, busy('Checking out %s…', 'Checking out %d files…', paths))
end

--- p4 add files into a changelist. `reconcile`: `paths` are `<dir>/...` paths, added by
--- `reconcile -a` (p4 add takes no wildcards): just the files under them not in the depot yet.
---@param ws perforated.Workspace
---@param paths string[]
---@param cl string?
---@param cb fun(ok: boolean, res: perforated.RunResult)?
---@param reconcile boolean?
function M.add(ws, paths, cl, cb, reconcile)
  local bufs = bufs_for(ws, paths)
  local add = reconcile and p4.reconcile_add or p4.add
  add(ws, paths, cl, function(res)
    local ok = #res.records > 0 and #res.errors == 0 and not res.stopped
    report('add', res, #res.records)
    changed(ws, { files = paths })
    for _, b in ipairs(bufs) do
      require('perforated.buffer').refresh(b)
    end
    if cb then
      cb(ok, res)
    end
  end, busy('Opening %s for add…', 'Opening %d files for add…', paths))
end

--- Revert files (confirmation is the caller's job). `unchanged` = `revert -a`.
---@param ws perforated.Workspace
---@param paths string[]
---@param unchanged boolean?
---@param cb fun(ok: boolean)?
function M.revert(ws, paths, unchanged, cb)
  if unchanged then
    -- `revert -a` compares the file on disk: a buffer with unsaved edits is changed, so keep
    -- it opened rather than reverting it and discarding those edits.
    paths = vim.tbl_filter(function(p)
      for _, b in ipairs(bufs_for(ws, { p })) do
        if vim.bo[b].modified then
          return false
        end
      end
      return true
    end, paths)
    if #paths == 0 then
      notify('revert unchanged: every file has unsaved changes')
      if cb then
        vim.schedule(function()
          cb(true)
        end)
      end
      return
    end
  end
  local bufs = bufs_for(ws, paths)
  local msg = unchanged
      and busy('Reverting %s if unchanged…', 'Reverting unchanged files…', paths)
    or busy('Reverting %s…', 'Reverting %d files…', paths)
  p4.revert(ws, paths, { unchanged = unchanged, busy = msg }, function(res)
    report(unchanged and 'revert unchanged' or 'revert', res, #res.records)
    changed(ws, { files = paths })
    local reverted = {}
    for _, rec in ipairs(res.records) do
      if rec.clientFile then
        reverted[p4.key(ws, rec.clientFile)] = true
      end
    end
    for _, b in ipairs(bufs) do
      local st = require('perforated.buffer').get(b)
      if st and reverted[st.key] and vim.api.nvim_buf_is_loaded(b) then
        -- Discard buffer changes: the user confirmed losing them.
        vim.api.nvim_buf_call(b, function()
          vim.cmd('silent! edit!')
        end)
      end
      require('perforated.buffer').refresh(b)
    end
    if cb then
      cb(res.ok)
    end
  end)
end

return M
