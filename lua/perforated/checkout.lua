--- Check-out on first modification, add on write, and the edit/add/revert operations.
---
--- Flow for an unopened depot file (read-only on disk with `noallwrite`):
---   first change → FileChangedRO (or the 'modified' flag for allwrite) → clear 'readonly' so Vim
---   doesn't warn → the change goes through → menu: <CR> sticky/default CL · c pick · n new ·
---   A always (session) · s skip (buffer; for add: this file, session) · S never (session) →
---   async `p4 edit` → refresh.
---   BufWritePre waits (bounded, Ctrl-C stops it) for an in-flight edit so the write never
---   races it; if p4 is still working then, the write is refused (the file goes read-only).

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
---@field refused_mode integer? the file's mode before a write that stopped waiting made it read-only

local cs = {} ---@type table<integer, perforated.CheckoutState>
-- Per Neovim session: never ask, always use the target, and files not to ask about again
-- (path → true; "don't ask again for this file" in the add prompt).
local session = { never = false, auto = false, skip_files = {} }

--- Did the user say not to ask about adding this file again? Paths, not cache keys: keys are
--- case-folded only once `p4 info` says the server is case-insensitive, so a key stored
--- before that would miss the folded one.
---@param ws perforated.Workspace
---@param path string
---@return boolean
function M._skipped(ws, path)
  if session.skip_files[path] then
    return true
  end
  if ws.icase then
    local folded = path:lower()
    for p in pairs(session.skip_files) do
      if p:lower() == folded then
        return true
      end
    end
  end
  return false
end
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

--- The directory a `<dir>/...` path covers (nil for any other path).
---@param path string
---@return string?
local function tree(path)
  return path:sub(-4) == '/...' and path:sub(1, -5) or nil -- (a pattern is slow on 100k paths)
end

--- Buffers of the given paths; a `<dir>/...` path takes every buffer under the directory.
---@param ws perforated.Workspace
---@param paths string[]
---@return integer[]
local function bufs_for(ws, paths)
  local want, dirs = {}, {}
  for _, p in ipairs(paths) do
    local dir = tree(p)
    if dir then
      dirs[#dirs + 1] = p4.key(ws, dir) .. '/'
    else
      want[p4.key(ws, p)] = true
    end
  end
  local out = {}
  for b, st in pairs(require('perforated.buffer').all()) do
    local hit = st.ws == ws and want[st.key]
    for _, d in ipairs(st.ws == ws and not hit and dirs or {}) do
      hit = hit or st.key:sub(1, #d) == d
    end
    if hit then
      out[#out + 1] = b
    end
  end
  return out
end

--- Most files a `Changed` event names; a bigger change asks listeners for a full refresh.
M.CHANGED_FILES_MAX = 500

--- Announce a change made from the plugin (`User PerforatedChanged`). `what` says what it
--- touched, so listeners can re-query only that: `files` (paths: their opened state and
--- content), `changes` (changelists: descriptions, shelves). Without it, anything may have
--- changed. Depot paths are named by their local path, or dropped (full refresh) when unknown.
---@param ws perforated.Workspace
---@param what { files: string[]?, changes: boolean? }?
local function changed(ws, what)
  local data = { ws = ws.key }
  if what then
    data.changes = what.changes
    local files = what.files and #what.files <= M.CHANGED_FILES_MAX and {} or nil
    for _, f in ipairs(what.files or {}) do
      local local_path = not f:find('...', 1, true) and f or nil -- a wildcard: refresh all
      if f:match('^//') then
        local rec = (ws.opened or {})[f]
        local_path = rec and rec.clientFile
      end
      if not (files and local_path) then
        files = nil
        break
      end
      files[#files + 1] = local_path
    end
    data.files = files
  end
  require('perforated.core.events').emit('Changed', data)
end
M.changed = changed

M.bufs_for = bufs_for
M._tree = tree

-- ---------------------------------------------------------------------------------------------
-- The edit/add/revert operations live in checkout_ops.lua (loaded on first use: nothing runs
-- them until a file is changed or a command is given, so they stay off the activation path).
-- ---------------------------------------------------------------------------------------------

function M.edit(...)
  return require('perforated.checkout_ops').edit(...)
end

function M.add(...)
  return require('perforated.checkout_ops').add(...)
end

function M.revert(...)
  return require('perforated.checkout_ops').revert(...)
end

function M.report(...)
  return require('perforated.checkout_ops').report(...)
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
      c.restore = c.restore or require('perforated.checkout_ops').optimistic_writable({ st.path })
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

--- Most a write waits for an in-flight edit of its file, in ms (nil = `runner.timeout`).
---@type integer?
M.WRITE_WAIT_MS = nil

--- Block (bounded, Ctrl-C stops it) until an in-flight edit finishes; check out on write when
--- configured.
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
    local name = vim.fn.fnamemodify(st.path, ':t')
    -- Drawn now: nothing else redraws during the wait (after a redraw, which would clear it).
    vim.cmd.redraw()
    vim.api.nvim_echo(
      { { ('Waiting for p4 edit of %s before writing… (Ctrl-C to stop)'):format(name) } },
      false,
      {}
    )
    local got = vim.wait(M.WRITE_WAIT_MS or config.get().runner.timeout, function()
      return not c.pending
    end, 10)
    vim.api.nvim_echo({ { '' } }, false, {})
    dbg.debug(
      'checkout',
      'buf %d write waited %.0fms for edit (done=%s, wait=%s)',
      buf,
      (vim.uv.hrtime() - t0) / 1e6,
      tostring(not c.pending),
      tostring(got)
    )
    if c.pending then
      -- Stopped (Ctrl-C) or out of time with p4 still working: the file was made writable
      -- ahead of the edit, so the write would land in a file p4 may yet refuse to open. Make
      -- it read-only again: Neovim refuses the write (E505), the buffer stays modified and
      -- `:wq` doesn't quit. The edit puts the mode back if it opens the file.
      local fst = vim.uv.fs_stat(st.path)
      if fst and vim.fn.filewritable(st.path) == 1 then
        c.refused_mode = fst.mode
        vim.uv.fs_chmod(st.path, bit.band(fst.mode, bit.bnot(tonumber('222', 8))))
      end
      notify(
        ('p4 edit of %s is still running: not written (:w again once it is checked out)'):format(
          name
        ),
        vim.log.levels.WARN
      )
    end
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
    or M._skipped(st.ws, st.path)
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
