--- M4 operations: shelve / unshelve / delete shelved files, submit, sync, delete, move.
--- No UI beyond confirmations and results; views call these and refresh on `User
--- PerforatedChanged`. Problems that concern files go to quickfix with p4's reason as text.

local p4 = require('perforated.p4')
local co = require('perforated.checkout')
local cls = require('perforated.changelists')

local M = {}

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- All messages of a result (errors first).
---@param res perforated.RunResult
---@return string[]
local function messages(res)
  return vim.list_extend(vim.list_extend({}, res.errors), res.warnings)
end

--- "<file> - <reason>" messages matching `pattern` (nil = any) as quickfix items.
---@param ws perforated.Workspace
---@param texts string[]
---@param pattern string?
---@param kind string
---@return table[]
local function file_items(ws, texts, pattern, kind)
  local qf = require('perforated.ui.qf')
  local items = {}
  for _, t in ipairs(texts) do
    local path, reason = t:match('^(%S+) %- (.+)$')
    if path and (not pattern or reason:find(pattern)) then
      local depot = path:gsub('#.*$', '')
      local local_path = depot
      if depot:match('^//') and ws.root then
        -- //client/... → workspace path; //depot/... is resolved when the entry is used
        local client = ws:client()
        if client and depot:sub(1, #client + 3) == '//' .. client .. '/' then
          local_path = ws.root .. depot:sub(#client + 3)
        end
      end
      items[#items + 1] = qf.item(local_path, reason, { depotFile = depot, kind = kind })
    end
  end
  return items
end
M._file_items = file_items

--- Refresh the state of workspace buffers (all of them, or the files given).
---@param ws perforated.Workspace
---@param paths string[]?
local function refresh(ws, paths)
  local buffer = require('perforated.buffer')
  if paths then
    for _, b in ipairs(co.bufs_for(ws, paths)) do
      buffer.refresh(b)
    end
    return
  end
  for b, st in pairs(buffer.all()) do
    if st.ws == ws then
      buffer.refresh(b)
    end
  end
end

local function confirm(msg, choices, default)
  return vim.fn.confirm(msg, choices or '&Yes\n&No', default or 2) == 1
end

-- ---------------------------------------------------------------------------------------------
-- Shelve
-- ---------------------------------------------------------------------------------------------

--- Shelve a changelist's opened files (or some of them), replacing shelved versions after a
--- confirmation.
---@param ws perforated.Workspace
---@param change string
---@param paths string[]?  nil = every file opened in the changelist
---@param cb fun(ok: boolean)?
function M.shelve(ws, change, paths, cb)
  cb = cb or function() end
  if change == 'default' then
    notify(
      'files in the default changelist cannot be shelved: move them to a numbered changelist first (M)',
      vim.log.levels.WARN
    )
    return cb(false)
  end
  cls.shelved_files(ws, { change }, function(sh)
    local existing = sh[change] or {}
    if #existing > 0 then
      local what = paths and (#paths .. ' file(s)') or 'the shelf'
      if
        not confirm(
          ('CL %s already has %d shelved file(s). Replace %s with your workspace versions?'):format(
            change,
            #existing,
            what
          ),
          '&Replace\n&Cancel'
        )
      then
        return cb(false)
      end
    end
    local args = { 'shelve', '-f', '-c', change }
    local opts = {}
    if paths then
      opts = { globals = { '-x', '-' }, stdin = paths }
    end
    ws:run(args, opts, function(res)
      co.report('shelve', res, #res.records)
      co.changed(ws)
      cb(#res.errors == 0 and #res.records > 0)
    end)
  end)
end

--- Delete shelved files (all of a changelist's, or some).
---@param ws perforated.Workspace
---@param change string
---@param depot_files string[]?
---@param cb fun(ok: boolean)?
function M.delete_shelved(ws, change, depot_files, cb)
  cb = cb or function() end
  local what = depot_files and (#depot_files == 1 and depot_files[1] or (#depot_files .. ' files'))
    or ('every shelved file of CL ' .. change)
  if not confirm(('Delete %s from the shelf?'):format(what), '&Delete\n&Cancel') then
    return cb(false)
  end
  local args = vim.list_extend({ 'shelve', '-d', '-c', change }, depot_files or {})
  ws:run(args, {}, function(res)
    if #res.errors > 0 then
      notify('delete shelved failed: ' .. res.errors[1], vim.log.levels.ERROR)
    else
      notify(('deleted shelved files of CL %s'):format(change))
    end
    co.changed(ws)
    cb(#res.errors == 0)
  end)
end

--- Unshelve into a changelist. Files that need a resolve (already opened) are listed in
--- quickfix; writable unopened files are only clobbered after a confirmation (`-f`).
---@param ws perforated.Workspace
---@param shelf string
---@param depot_files string[]?  nil = every shelved file
---@param target string?  nil = the shelf's own changelist when it is ours, else a picked one
---@param cb fun(ok: boolean)?
function M.unshelve(ws, shelf, depot_files, target, cb)
  cb = cb or function() end
  local function run(into, force)
    local args = { 'unshelve', '-s', shelf, '-c', into }
    if force then
      table.insert(args, 2, '-f')
    end
    vim.list_extend(args, depot_files or {})
    ws:run(args, {}, function(res)
      local texts = messages(res)
      local clobber = false
      for _, t in ipairs(res.errors) do
        if t:find("can't clobber", 1, true) then
          clobber = true
        end
      end
      if clobber and not force then
        if
          confirm(
            'Some workspace files are writable but not opened. Overwrite them with the shelved versions?',
            '&Overwrite\n&Cancel'
          )
        then
          return run(into, true)
        end
      end
      local unshelved = 0
      for _, t in ipairs(texts) do
        if t:find(' %- unshelved') then
          unshelved = unshelved + 1
        end
      end
      unshelved = math.max(unshelved, #res.records)
      local resolve = file_items(ws, texts, 'must resolve', 'unresolved')
      if #res.errors > 0 and unshelved == 0 then
        notify('unshelve failed: ' .. res.errors[1], vim.log.levels.ERROR)
      else
        notify(
          ('unshelved %d file(s) from CL %s into %s'):format(
            unshelved,
            shelf,
            into == 'default' and 'the default changelist' or ('CL ' .. into)
          )
        )
      end
      if #resolve > 0 then
        require('perforated.ui.qf').set({
          title = 'P4 unshelve · must resolve',
          kind = 'unresolved',
          items = resolve,
        })
      end
      co.changed(ws)
      refresh(ws)
      cb(unshelved > 0)
    end)
  end
  if target then
    return run(target)
  end
  p4.pending_changes(ws, function(changes)
    for _, c in ipairs(changes or {}) do
      if c.change == shelf then
        return run(shelf) -- our own pending changelist in this client
      end
    end
    co.pick_change(ws, function(cl)
      if cl then
        run(cl)
      else
        cb(false)
      end
    end)
  end)
end

--- Delete a pending changelist. p4 only deletes an empty one, so after a single confirmation
--- its opened files are moved to the default changelist (or reverted) and its shelved files are
--- deleted first. Changelists of other clients need `change.allow_force` (`change -d -f`).
---@param ws perforated.Workspace
---@param change string
---@param cb fun(ok: boolean)?
function M.delete_change(ws, change, cb)
  cb = cb or function() end
  if change == 'default' then
    notify('the default changelist cannot be deleted', vim.log.levels.WARN)
    return cb(false)
  end
  cls.describe(ws, { change }, {}, function(by)
    local d = by[change]
    if not d or d.rec.status ~= 'pending' then
      notify(('CL %s is not a pending changelist'):format(change), vim.log.levels.ERROR)
      return cb(false)
    end
    local force = d.rec.client ~= ws:client()
    if force and not require('perforated.config').get().change.allow_force then
      notify(
        ('CL %s belongs to client %s: deleting it needs change.allow_force (p4 change -d -f)'):format(
          change,
          d.rec.client or '?'
        ),
        vim.log.levels.WARN
      )
      return cb(false)
    end
    p4.fstat_opened(ws, {}, function(recs)
      local paths = {}
      for _, r in ipairs(recs or {}) do
        if r.change == change and r.clientFile then
          paths[#paths + 1] = r.clientFile
        end
      end
      cls.shelved_files(ws, { change }, function(sh)
        local nshelved = #(sh[change] or {})
        local what = {}
        if #paths > 0 then
          what[#what + 1] = ('%d opened file(s)'):format(#paths)
        end
        if nshelved > 0 then
          what[#what + 1] = ('%d shelved file(s), which will be deleted'):format(nshelved)
        end
        local title = ('Delete CL %s (%s)?'):format(
          change,
          vim.trim((d.rec.desc or ''):match('[^\n]*') or '')
        )
        local msg = #what > 0 and (title .. '\nIt has ' .. table.concat(what, ' and ') .. '.')
          or title
        local mode
        if #paths > 0 then
          local choice = vim.fn.confirm(
            msg .. '\nIts opened files:',
            '&Move them to the default changelist\n&Revert them (edits are lost)\n&Cancel',
            3
          )
          mode = ({ 'move', 'revert' })[choice]
        else
          mode = confirm(msg, '&Delete\n&Cancel') and 'delete' or nil
        end
        if not mode then
          return cb(false)
        end
        local function delete()
          local args = force and { 'change', '-d', '-f', change } or { 'change', '-d', change }
          ws:run(args, {}, function(res)
            local ok = #res.errors == 0
            if ok then
              notify(('deleted CL %s'):format(change))
              if ws.sticky_cl == change then
                ws.sticky_cl, ws.sticky_desc = nil, nil
              end
            else
              notify(
                ('could not delete CL %s: %s'):format(change, res.errors[1]),
                vim.log.levels.ERROR
              )
            end
            co.changed(ws)
            cb(ok)
          end)
        end
        local function empty_files()
          if #paths == 0 then
            return delete()
          end
          if mode == 'revert' then
            return co.revert(ws, paths, false, function()
              delete()
            end)
          end
          cls.reopen(ws, paths, 'default', function(res)
            if #res.errors > 0 then
              notify('could not move the files: ' .. res.errors[1], vim.log.levels.ERROR)
              co.changed(ws)
              return cb(false)
            end
            refresh(ws, paths)
            delete()
          end)
        end
        if nshelved == 0 then
          return empty_files()
        end
        local args = force and { 'shelve', '-d', '-f', '-c', change }
          or { 'shelve', '-d', '-c', change }
        ws:run(args, {}, function(res)
          if #res.errors > 0 then
            notify('could not delete the shelf: ' .. res.errors[1], vim.log.levels.ERROR)
            co.changed(ws)
            return cb(false)
          end
          empty_files()
        end)
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Submit
-- ---------------------------------------------------------------------------------------------

--- Run the submit itself.
---@param ws perforated.Workspace
---@param change string
---@param desc string?  required for the default changelist
---@param cb fun(ok: boolean, submitted: string?)
function M.run_submit(ws, change, desc, cb)
  local args = change == 'default' and { 'submit', '-d', desc or '' } or { 'submit', '-c', change }
  local label = change == 'default' and 'the default changelist' or ('CL ' .. change)
  local jobs = require('perforated.jobs')
  p4.fstat_opened(ws, {}, function(before)
    local paths = {}
    for _, r in ipairs(before or {}) do
      if (r.change or 'default') == change and r.clientFile then
        paths[#paths + 1] = r.clientFile
      end
    end
    local job, run_opts = jobs.start(ws, 'submit ' .. label)
    ws:run(args, run_opts, function(res)
      local submitted
      for _, r in ipairs(res.records) do
        submitted = submitted or r.submittedChange
      end
      local texts = messages(res)
      if submitted then
        jobs.finish(job, ('submitted %s as CL %s (%d file(s))'):format(label, submitted, #paths))
        if ws.sticky_cl == change then
          ws.sticky_cl, ws.sticky_desc = nil, nil
        end
      else
        local renumbered
        for _, t in ipairs(texts) do
          renumbered = renumbered or t:match('p4 submit %-c (%d+)')
        end
        local first = res.errors[1] or texts[1] or 'submit failed'
        jobs.finish(job, res.cancelled and 'submit stopped' or ('submit failed: ' .. first), true)
        local items = file_items(ws, texts, nil, 'submit_error')
        if #items > 0 then
          require('perforated.ui.qf').set({
            title = 'P4 submit '
              .. label
              .. ' · failed'
              .. (renumbered and (' (now CL ' .. renumbered .. ')') or ''),
            kind = 'submit_error',
            items = items,
          })
        end
      end
      co.changed(ws)
      refresh(ws, paths)
      cb(submitted ~= nil, submitted)
    end)
  end)
end

--- `P` / `:P4 submit [CL]`: a confirmation float (files, description, warnings about stale,
--- unresolved or shelved files), then submit.
---@param ws perforated.Workspace
---@param change string
---@param cb fun(ok: boolean)?
function M.submit(ws, change, cb)
  cb = cb or function() end
  local status = require('perforated.status')
  local function show(desc, files, shelved)
    if #files == 0 then
      notify(
        ('nothing to submit in %s'):format(
          change == 'default' and 'the default changelist' or ('CL ' .. change)
        ),
        vim.log.levels.WARN
      )
      return cb(false)
    end
    local header = {}
    for _, l in ipairs(vim.split(vim.trim(desc or ''), '\n', { plain = true })) do
      if #header < 6 then
        header[#header + 1] = '  ' .. l
      end
    end
    if change == 'default' then
      header = { '  (the default changelist: you will be asked for a description)' }
    end
    header[#header + 1] = ''
    local nstale, nunres = 0, 0
    for _, f in ipairs(files) do
      if status.is_stale(f) then
        nstale = nstale + 1
      end
      if f.unresolved then
        nunres = nunres + 1
      end
    end
    header[#header + 1] = ('  %d file(s)'):format(#files)
    if nstale > 0 then
      header[#header + 1] = ('  ⚠ %d file(s) out of date: submit will fail until you sync and resolve'):format(
        nstale
      )
    end
    if nunres > 0 then
      header[#header + 1] = ('  ⚠ %d file(s) need resolving'):format(nunres)
    end
    if shelved > 0 then
      header[#header + 1] = ('  ⚠ %d shelved file(s): p4 refuses to submit until the shelf is deleted (z)'):format(
        shelved
      )
    end
    local items = {
      { key = 's', label = 'Submit', value = 'submit' },
      { key = 'c', label = 'Cancel', value = 'cancel' },
    }
    if change ~= 'default' then
      table.insert(items, 2, { key = 'e', label = 'Edit the description first', value = 'edit' })
    end
    local choice = require('perforated.ui.float').menu({
      title = change == 'default' and 'Submit the default changelist' or ('Submit CL ' .. change),
      header = header,
      items = items,
      relative = 'editor',
    })
    local v = choice and choice.value
    if v == 'edit' then
      return require('perforated.views.change_editor').edit(ws, change, {
        on_done = function(saved)
          if saved ~= nil then
            M.submit(ws, change, cb)
          end
        end,
      })
    elseif v ~= 'submit' then
      return cb(false)
    end
    if change == 'default' then
      return vim.ui.input({ prompt = 'Submit description: ' }, function(input)
        if not input or vim.trim(input) == '' then
          return cb(false)
        end
        M.run_submit(ws, change, input, cb)
      end)
    end
    M.run_submit(ws, change, nil, cb)
  end
  -- Fresh state for the warnings: `fstat -Ro` of opened files (stale / unresolved).
  p4.fstat_opened(ws, {}, function(recs)
    local files = {}
    for _, r in ipairs(recs or {}) do
      if (r.change or 'default') == change then
        files[#files + 1] = r
      end
    end
    if change == 'default' then
      return show(nil, files, 0)
    end
    cls.describe(ws, { change }, {}, function(by)
      cls.shelved_files(ws, { change }, function(sh)
        show(by[change] and by[change].rec.desc, files, #(sh[change] or {}))
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Sync
-- ---------------------------------------------------------------------------------------------

--- Reload unmodified buffers whose files changed on disk (no "file changed" prompts).
---@param ws perforated.Workspace
---@param paths string[]
function M.reload(ws, paths)
  for _, b in ipairs(co.bufs_for(ws, paths)) do
    if vim.api.nvim_buf_is_loaded(b) and not vim.bo[b].modified then
      local views = {}
      for _, w in ipairs(vim.fn.win_findbuf(b)) do
        views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
      end
      vim.api.nvim_buf_call(b, function()
        vim.cmd('silent! edit')
      end)
      for w, v in pairs(views) do
        pcall(vim.api.nvim_win_call, w, function()
          vim.fn.winrestview(v)
        end)
      end
    end
  end
end

--- `:P4 sync [args]` / `gy`: sync (no args = the whole workspace). Reloads affected buffers;
--- files that need attention (can't clobber, must resolve) go to quickfix.
---@param ws perforated.Workspace
---@param args string[]?  paths and revisions (`file#head`, `//...@123`, …)
---@param cb fun(ok: boolean)?
function M.sync(ws, args, cb)
  cb = cb or function() end
  args = args or {}
  local what = #args == 0 and 'workspace' or table.concat(args, ' ')
  local jobs = require('perforated.jobs')
  local job, run_opts = jobs.start(ws, 'sync ' .. what)
  ws:run(vim.list_extend({ 'sync' }, args), run_opts, function(res)
    local changed_paths, counts = {}, {}
    for _, r in ipairs(res.records) do
      if r.clientFile then
        changed_paths[#changed_paths + 1] = r.clientFile
        counts[r.action or '?'] = (counts[r.action or '?'] or 0) + 1
      end
    end
    local texts = messages(res)
    local attention = file_items(ws, texts, "can't clobber", 'sync_attention')
    vim.list_extend(attention, file_items(ws, texts, 'must resolve', 'unresolved'))
    local parts = {}
    for action, n in pairs(counts) do
      parts[#parts + 1] = ('%d %s'):format(n, action)
    end
    table.sort(parts)
    local failed = #res.errors > 0 and #changed_paths == 0 and #attention == 0
    local summary = #parts > 0 and table.concat(parts, ', ')
      or (texts[1] and texts[1]:find('up%-to%-date') and 'up to date')
      or (failed and res.errors[1])
      or 'nothing to sync'
    if res.cancelled then
      summary = ('stopped after %d file(s)'):format(#changed_paths)
    end
    jobs.finish(
      job,
      summary .. (#attention > 0 and (' · %d need attention'):format(#attention) or ''),
      failed or res.cancelled
    )
    M.reload(ws, changed_paths)
    co.changed(ws)
    refresh(ws)
    -- Fresh state of every opened file: the list covers *all* unresolved files, not just the
    -- ones this sync reported.
    require('perforated.poll').refresh(ws, {}, function()
      M.after_sync(ws, texts, attention)
      cb(not failed and not res.cancelled)
    end)
  end)
end

--- After a sync: quickfix of files that need attention (can't clobber + every unresolved file
--- in the workspace), and an offer to resolve now (`sync.resolve_prompt`).
---@param ws perforated.Workspace
---@param texts string[]  the sync's messages
---@param reported table[]  quickfix items from those messages
function M.after_sync(ws, texts, reported)
  local qf = require('perforated.ui.qf')
  local items = file_items(ws, texts, "can't clobber", 'sync_attention')
  local unresolved = {}
  if ws.opened then
    for _, r in pairs(ws.opened) do
      if r.unresolved and r.clientFile then
        unresolved[#unresolved + 1] = r
      end
    end
    table.sort(unresolved, function(a, b)
      return a.clientFile < b.clientFile
    end)
    for _, r in ipairs(unresolved) do
      items[#items + 1] = qf.item(
        r.clientFile,
        ('must resolve (#%s, head #%s)'):format(r.haveRev or '?', r.headRev or '?'),
        { depotFile = r.depotFile, change = r.change, action = r.action, kind = 'unresolved' }
      )
    end
  else
    items = reported -- no fresh state: what the sync itself reported
  end
  if #items == 0 then
    return
  end
  qf.set({
    title = ('P4 sync · %d file(s) need attention (R resolves)'):format(#items),
    kind = 'sync_attention',
    items = items,
  })
  if #unresolved == 0 or require('perforated.config').get().sync.resolve_prompt == false then
    return
  end
  local float = require('perforated.ui.float')
  local choice, replay = float.menu({
    title = 'Sync',
    header = { ('%d file(s) need resolving'):format(#unresolved) },
    items = {
      { key = 'r', label = 'Resolve now (auto-merge, then your merge tool)', value = 'resolve' },
      { key = 'l', label = 'Later (R in the quickfix list)', value = 'later' },
    },
    relative = 'editor',
    grace = require('perforated.config').get().checkout.prompt_grace,
  })
  if replay ~= '' then
    float.replay(replay)
  end
  if choice and choice.value == 'resolve' then
    require('perforated.resolve').run(
      ws,
      vim.tbl_map(function(r)
        return r.clientFile
      end, unresolved)
    )
  end
end

-- ---------------------------------------------------------------------------------------------
-- Delete / move
-- ---------------------------------------------------------------------------------------------

--- `:P4 delete [file…]`: open files for delete (after a confirmation). p4 removes them from
--- disk; their unmodified buffers are wiped.
---@param ws perforated.Workspace
---@param paths string[]
---@param cb fun(ok: boolean)?
function M.delete(ws, paths, cb)
  cb = cb or function() end
  local what = #paths == 1 and vim.fn.fnamemodify(paths[1], ':~:.') or (#paths .. ' files')
  if
    not confirm(
      ('Open %s for delete? It is removed from your workspace.'):format(what),
      '&Delete\n&Cancel'
    )
  then
    return cb(false)
  end
  local bufs = co.bufs_for(ws, paths)
  ws:run({ 'delete' }, { globals = { '-x', '-' }, stdin = paths }, function(res)
    local deleted = {}
    for _, r in ipairs(res.records) do
      if r.clientFile and r.action == 'delete' then
        deleted[p4.key(ws, r.clientFile)] = true
      end
    end
    local problems = {}
    for _, t in ipairs(messages(res)) do
      if t:find("can't delete", 1, true) or t:find('not on client', 1, true) then
        problems[#problems + 1] = t
      end
    end
    if next(deleted) then
      notify(('opened %d file(s) for delete'):format(vim.tbl_count(deleted)))
    end
    if #problems > 0 then
      notify(problems[1], vim.log.levels.WARN)
    end
    for _, b in ipairs(bufs) do
      local st = require('perforated.buffer').get(b)
      if st and deleted[st.key] then
        if vim.bo[b].modified then
          require('perforated.buffer').refresh(b)
        else
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
    co.changed(ws)
    cb(next(deleted) ~= nil)
  end)
end

--- `:P4 move {new}`: rename the current file in Perforce (opening it for edit first if
--- needed), then rename its buffer and keep editing.
---@param buf integer
---@param new string
---@param cb fun(ok: boolean)?
function M.move(buf, new, cb)
  cb = cb or function() end
  local buffer = require('perforated.buffer')
  local st = buffer.get(buf)
  if not st or not st.rec then
    notify('not a Perforce depot file', vim.log.levels.WARN)
    return cb(false)
  end
  local ws, old = st.ws, st.path
  new = vim.fn.fnamemodify(vim.fn.expand(new), ':p')
  if vim.fn.isdirectory(new) == 1 then
    new = new:gsub('/$', '') .. '/' .. vim.fs.basename(old)
  end
  if vim.uv.fs_stat(new) then
    notify(new .. ' already exists', vim.log.levels.ERROR)
    return cb(false)
  end
  local function move()
    ws:run({ 'move', old, new }, {}, function(res)
      local ok = false
      for _, r in ipairs(res.records) do
        if r.action == 'move/add' then
          ok = true
        end
      end
      if not ok then
        notify('move failed: ' .. (res.errors[1] or res.warnings[1] or '?'), vim.log.levels.ERROR)
        return cb(false)
      end
      -- p4 moved the file on disk: follow it with the buffer (unsaved edits are kept and
      -- written to the new path).
      buffer.detach(buf)
      local oldbuf_name = vim.api.nvim_buf_get_name(buf)
      vim.api.nvim_buf_set_name(buf, new)
      vim.api.nvim_buf_call(buf, function()
        vim.cmd('silent! write!')
      end)
      local alt = vim.fn.bufnr(oldbuf_name)
      if alt > 0 and alt ~= buf and not vim.api.nvim_buf_is_loaded(alt) then
        pcall(vim.api.nvim_buf_delete, alt, { force = true })
      end
      require('perforated.core.activation').attach(
        buf,
        new,
        require('perforated.gate').lookup(vim.fs.dirname(new))
      )
      notify(('moved to %s'):format(vim.fn.fnamemodify(new, ':~:.')))
      co.changed(ws)
      cb(true)
    end)
  end
  if st.rec.action then
    return move()
  end
  co.edit(ws, { old }, ws.sticky_cl, function(ok)
    if ok then
      move()
    else
      cb(false)
    end
  end)
end

return M
