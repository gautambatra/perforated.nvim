--- Check-out on first modification, add on write, and the edit/add/revert operations.
---
--- Flow for an unopened depot file (read-only on disk with `noallwrite`):
---   first change → FileChangedRO (or the 'modified' flag for allwrite) → clear 'readonly' so Vim
---   doesn't warn → the change goes through → menu: <CR> sticky/default CL · c pick · n new ·
---   A always (session) · s skip (buffer; for add: this file, session) · S never (session) →
---   async `p4 edit` → refresh.
---   BufWritePre waits (bounded) for an in-flight edit so the write never races it.

local p4 = require('perforated.p4')
local config = require('perforated.config')
local dbg = require('perforated.core.debug')

local M = {}

---@class perforated.CheckoutState
---@field skip boolean?      user chose skip for this buffer
---@field wanted boolean?    modified before fstat answered; prompt once status is known
---@field pending boolean?   p4 edit/add in flight
---@field prompting boolean?
---@field scheduled boolean? a prompt is queued (FileChangedRO and the 'modified' hook both fire)
---@field restore fun()?     undo an optimistic chmod (on_write mode) if the edit fails

local cs = {} ---@type table<integer, perforated.CheckoutState>
-- Per Neovim session: never ask, always use the target, and files not to ask about again
-- (key → true; "don't ask again for this file" in the add prompt).
local session = { never = false, auto = false, skip_files = {} }
local group = vim.api.nvim_create_augroup('perforated.checkout', { clear = true })

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

---@param buf integer
---@return perforated.CheckoutState
local function state(buf)
  cs[buf] = cs[buf] or {}
  return cs[buf]
end

--- Is automatic check-out enabled for this path (checkout.dirs allow-list)?
---@param path string
---@return boolean
local function allowed(path)
  local dirs = config.get().checkout.dirs
  if not dirs then
    return true
  end
  for _, d in ipairs(dirs) do
    d = vim.fs.normalize(d)
    if path == d or path:sub(1, #d + 1) == d .. '/' then
      return true
    end
  end
  return false
end

---@param ws perforated.Workspace
---@param paths string[]
---@return integer[]
local function bufs_for(ws, paths)
  local want = {}
  for _, p in ipairs(paths) do
    want[p4.key(ws, p)] = true
  end
  local out = {}
  for b, st in pairs(require('perforated.buffer').all()) do
    if st.ws == ws and want[st.key] then
      out[#out + 1] = b
    end
  end
  return out
end

--- Report the outcome of a file command: short message on success, errors (with file names)
--- as a notification — lists go to quickfix once M2's qf sink exists.
---@param verb string
---@param res perforated.RunResult
---@param count integer
local function changed(ws)
  require('perforated.core.events').emit('Changed', { ws = ws.key })
end
M.changed = changed

local function report(verb, res, count)
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
      ('%s failed: %s'):format(verb, vim.trim(res.stderr ~= '' and res.stderr or 'unknown error')),
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

M.bufs_for = bufs_for
M.report = report

-- ---------------------------------------------------------------------------------------------
-- Operations (also used by commands)
-- ---------------------------------------------------------------------------------------------

--- Make read-only files writable right away (what `p4 edit` is about to do anyway), so a
--- `:w` issued before the server answers passes Neovim's permission check (E505), which runs
--- before any write autocmd. Returns a function restoring the original modes, except for the
--- paths in `keep` (a set of paths p4 did open).
---@param paths string[]
---@return fun(keep: table<string, true>?)
local function optimistic_writable(paths)
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

--- "Checking out a.c…" in the middle of the screen while p4 works (it can take a moment, and
--- nothing else shows that something is happening). Returns the closer.
---@param fmt_one string   e.g. 'Checking out %s…'
---@param fmt_many string  e.g. 'Checking out %d files…'
---@param paths string[]
---@return fun()
local function busy(fmt_one, fmt_many, paths)
  local msg = #paths == 1 and fmt_one:format(vim.fn.fnamemodify(paths[1], ':t'))
    or fmt_many:format(#paths)
  return require('perforated.ui.toast').busy(msg)
end

--- p4 edit files into a changelist (nil/'default' = default CL).
---@param ws perforated.Workspace
---@param paths string[]
---@param cl string?
---@param cb fun(ok: boolean)?
function M.edit(ws, paths, cl, cb)
  local bufs = bufs_for(ws, paths)
  for _, b in ipairs(bufs) do
    state(b).pending = true
  end
  local restore = optimistic_writable(paths)
  local done = busy('Checking out %s…', 'Checking out %d files…', paths)
  p4.edit(ws, paths, cl, function(res)
    done()
    for _, b in ipairs(bufs) do
      state(b).pending = false
    end
    local ok = #res.records > 0 and #res.errors == 0
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
      local keep = {}
      for _, p in ipairs(paths) do
        if opened[vim.fs.normalize(p)] then
          keep[p] = true
        end
      end
      restore(keep)
    end
    report('edit', res, #res.records)
    changed(ws)
    for _, b in ipairs(bufs) do
      if ok and vim.api.nvim_buf_is_valid(b) then
        vim.bo[b].readonly = false
      end
      require('perforated.buffer').refresh(b)
    end
    if cb then
      cb(ok)
    end
  end)
end

---@param ws perforated.Workspace
---@param paths string[]
---@param cl string?
---@param cb fun(ok: boolean)?
function M.add(ws, paths, cl, cb)
  local bufs = bufs_for(ws, paths)
  local done = busy('Opening %s for add…', 'Opening %d files for add…', paths)
  p4.add(ws, paths, cl, function(res)
    done()
    local ok = #res.records > 0 and #res.errors == 0
    report('add', res, #res.records)
    changed(ws)
    for _, b in ipairs(bufs) do
      require('perforated.buffer').refresh(b)
    end
    if cb then
      cb(ok)
    end
  end)
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
  local done = unchanged
      and busy('Reverting %s if unchanged…', 'Reverting unchanged files…', paths)
    or busy('Reverting %s…', 'Reverting %d files…', paths)
  p4.revert(ws, paths, { unchanged = unchanged }, function(res)
    done()
    report(unchanged and 'revert unchanged' or 'revert', res, #res.records)
    changed(ws)
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

-- ---------------------------------------------------------------------------------------------
-- Changelist choice and the prompt live in checkout_prompt.lua (loaded on first use: they're
-- only needed when a file is first modified, not on the activation path).
-- ---------------------------------------------------------------------------------------------

function M.pick_change(...)
  return require('perforated.checkout_prompt').pick_change(...)
end

function M.new_change(...)
  return require('perforated.checkout_prompt').new_change(...)
end

function M.prompt(...)
  return require('perforated.checkout_prompt').prompt(...)
end

-- ---------------------------------------------------------------------------------------------
-- Autocmd hooks
-- ---------------------------------------------------------------------------------------------

---@param buf integer
local function on_first_change(buf)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return
  end
  local c = state(buf)
  dbg.debug(
    'checkout',
    'buf %d first change: status=%s skip=%s pending=%s scheduled=%s never=%s auto=%s allowed=%s',
    buf,
    st.status,
    tostring(c.skip),
    tostring(c.pending),
    tostring(c.scheduled),
    tostring(session.never),
    tostring(session.auto),
    tostring(allowed(st.path))
  )
  if st.status == 'pending' then
    c.wanted = true -- decide once fstat answers
    return
  end
  if
    st.status ~= 'clean'
    or c.skip
    or c.pending
    or c.scheduled
    or session.never
    or not allowed(st.path)
  then
    return
  end
  local cfg = config.get().checkout
  vim.bo[buf].readonly = false -- the prompt replaces Vim's W10 warning
  if session.auto or not cfg.prompt then
    if cfg.on_write and not session.auto then
      -- Check out silently when the buffer is written. The file must already be writable by
      -- then (Neovim's E505 check precedes BufWritePre); restored if the edit fails.
      c.restore = c.restore or optimistic_writable({ st.path })
      return
    end
    return M.edit(st.ws, { st.path }, st.ws.sticky_cl)
  end
  c.scheduled = true
  vim.schedule(function()
    local cur = require('perforated.buffer').get(buf)
    if cur and cur.status == 'clean' and vim.api.nvim_buf_is_valid(buf) then
      M.prompt(buf, 'edit')
    end
    c.scheduled = false
  end)
end

--- Called by buffer.lua whenever a buffer's status changes.
---@param buf integer
---@param prev perforated.BufStatus
---@param new perforated.BufStatus
function M.on_status(buf, prev, new)
  local c = state(buf)
  if new == 'opened' or new == 'binary' then
    if
      vim.api.nvim_buf_is_valid(buf) and vim.fn.filewritable(vim.api.nvim_buf_get_name(buf)) == 1
    then
      vim.bo[buf].readonly = false
    end
  elseif new == 'clean' and prev == 'pending' and c.wanted then
    c.wanted = false
    on_first_change(buf)
  end
end

--- The file a write goes to, when it isn't the buffer's own (`:w other.c` writes there but
--- the buffer keeps its name).
---@param st perforated.BufState
---@param ev table  autocmd event (`match` is the full name of the file written)
---@return string?
local function other_target(st, ev)
  local target = ev and ev.match and ev.match ~= '' and vim.fs.normalize(ev.match)
  if target and target ~= vim.fs.normalize(st.path) then
    return target
  end
end

--- Block (bounded) until an in-flight edit finishes; check out on write when configured.
---@param buf integer
---@param ev table
local function before_write(buf, ev)
  local st = require('perforated.buffer').get(buf)
  local c = state(buf)
  if not st or other_target(st, ev) then
    return
  end
  local cfg = config.get().checkout
  if
    st.status == 'clean'
    and not c.pending
    and not c.skip
    and not session.never
    and allowed(st.path)
    and (cfg.on_write or session.auto or not cfg.prompt)
  then
    local restore = c.restore
    c.restore = nil
    M.edit(st.ws, { st.path }, st.ws.sticky_cl, function(ok)
      if not ok and restore then
        restore()
      end
    end)
  end
  if c.pending then
    local t0 = vim.uv.hrtime()
    vim.wait(config.get().runner.timeout, function()
      return not c.pending
    end, 10)
    dbg.debug(
      'checkout',
      'buf %d write waited %.0fms for edit (done=%s)',
      buf,
      (vim.uv.hrtime() - t0) / 1e6,
      tostring(not c.pending)
    )
  end
end

---@param buf integer
---@param ev table
local function after_write(buf, ev)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return
  end
  local other = other_target(st, ev)
  if other then
    return require('perforated.checkout_prompt').add_other(other)
  end
  local c = state(buf)
  if
    st.status ~= 'new'
    or c.skip
    or session.never
    or session.skip_files[st.key]
    or not allowed(st.path)
  then
    return
  end
  local mode = config.get().checkout.add_on_write
  if mode == false or mode == 'never' then
    return
  elseif mode == 'auto' then
    return M.add(st.ws, { st.path }, st.ws.sticky_cl)
  end
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      M.prompt(buf, 'add')
    end
  end)
end

--- Remember the file's modification time and size as of now (read or written): the same moment
--- Neovim records its own, so a later "file changed" event can be checked against it.
---@param buf integer
local function remember_disk(buf)
  local st = require('perforated.buffer').get(buf)
  local s = st and vim.uv.fs_stat(st.path)
  if st then
    st.disk = s and { sec = s.mtime.sec, nsec = s.mtime.nsec, size = s.size } or nil
  end
end

--- Is a "file changed" event for this buffer only about the file's permissions?
--- `p4 edit` / `revert` flip them. Neovim reports that as `mode`, but as `conflict` (W12, "the
--- buffer was changed in Vim as well") when the buffer has unsaved edits, which is the usual
--- case right after a check-out. So: same modification time and size as when the buffer was
--- read or last written → only the permissions changed. One stat; the file isn't read.
---@param buf integer
---@param reason string  v:fcs_reason
---@return boolean
function M._metadata_only(buf, reason)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return false
  end
  if reason == 'mode' then
    return true
  end
  if reason ~= 'conflict' and reason ~= 'changed' then
    return false
  end
  local was, s = st.disk, vim.uv.fs_stat(st.path)
  return was ~= nil
    and s ~= nil
    and s.size == was.size
    and s.mtime.sec == was.sec
    and s.mtime.nsec == was.nsec
end

local did_autocmds = false

--- Install the (global) hooks once; they only act on buffers perforated tracks, so the
--- per-buffer cost is a table lookup rather than six autocmds and closures per buffer.
---@param attached integer the buffer being attached
function M.attach(attached)
  remember_disk(attached) -- attached right after Neovim read the file
  if did_autocmds then
    return
  end
  did_autocmds = true
  local tracked = require('perforated.buffer').get
  local function on(event, fn)
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = function(ev)
        if tracked(ev.buf) then
          fn(ev.buf, ev)
        end
      end,
    })
  end
  on('FileChangedRO', on_first_change)
  -- allwrite workspaces: files aren't read-only, so FileChangedRO never fires; watch the
  -- 'modified' flag instead.
  local function modified(buf)
    if vim.bo[buf].modified and not vim.bo[buf].readonly then
      local st = tracked(buf)
      if st.status == 'clean' or st.status == 'pending' then
        on_first_change(buf)
      end
    end
  end
  if vim.fn.exists('##BufModifiedSet') == 1 then
    on('BufModifiedSet', modified)
  else
    -- Neovim 0.13+ removed BufModifiedSet: OptionSet fires for 'modified' instead.
    vim.api.nvim_create_autocmd('OptionSet', {
      group = group,
      pattern = 'modified',
      callback = function()
        local buf = vim.api.nvim_get_current_buf()
        if tracked(buf) then
          modified(buf)
        end
      end,
    })
  end
  -- Registered for every buffer: once a FileChangedShell autocmd exists, Neovim does what
  -- v:fcs_choice says instead of warning, so untracked buffers must get 'ask' too.
  vim.api.nvim_create_autocmd('FileChangedShell', {
    group = group,
    callback = function(ev)
      -- `p4 edit` flips the file's mode bit: never bother the user about that.
      vim.v.fcs_choice = M._metadata_only(ev.buf, vim.v.fcs_reason) and '' or 'ask'
    end,
  })
  on('BufWritePre', before_write)
  on('BufWritePost', function(b, ev)
    remember_disk(b)
    after_write(b, ev)
  end)
  -- Re-reading the file (:e!) starts over: a skipped/cancelled buffer prompts again.
  -- A file made writable for check-out on write, but never written, goes back to read-only.
  local function drop(buf)
    local c = cs[buf]
    if c and not c.pending then
      if c.restore then
        c.restore()
      end
      cs[buf] = nil
    end
  end
  on('BufReadPost', function(b)
    remember_disk(b)
    drop(b)
  end)
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(ev)
      drop(ev.buf)
      cs[ev.buf] = nil
    end,
  })
end

--- Session-wide prompt switches (never ask / always use the target / files not to ask about).
M._session = session
M._allowed = allowed

--- A buffer's check-out state (also used by checkout_prompt).
function M._state(buf)
  return state(buf == 0 and vim.api.nvim_get_current_buf() or buf)
end

--- Test helper.
function M._reset()
  cs = {}
  session.never, session.auto, session.skip_files = false, false, {}
end

return M
