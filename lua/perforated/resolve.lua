--- Resolve (`R`, `:P4 resolve`), the way `p4 resolve` does it — no merge logic here:
---
---   1. `resolve -am`: p4 accepts every clean merge.
---   2. For each remaining content conflict: base and theirs are printed to temp files, and
---      the merge tool ($P4MERGE or `merge.tool`) runs asynchronously as
---      `tool base theirs yours merged` (p4's convention).
---   3. Exit 0 with a changed result: the result is written to the workspace file (through its
---      buffer when loaded) and accepted with `resolve -ay`. Anything else leaves the file
---      unresolved.
---
--- Files still unresolved at the end (tool cancelled, non-content resolves, no tool) go to
--- quickfix, where `R` on an entry resumes.
---
--- It runs as a job (`:P4 jobs`, `:P4 cancel`): `resolve -am` merges on this machine after
--- fetching each file's revisions, which can take far longer than the usual call timeout on a
--- real server. While p4 works a centred busy pop-up says so (closed while the merge tool
--- runs, so it doesn't cover it); at the end a centred pop-up that waits for a key says what
--- happened: merged automatically, with the merge tool, and every file left unresolved with
--- its reason.

local M = {}

---@param file string
---@param rev string?
---@return string?
local function spec_of(file, rev)
  if not file or not rev or rev == 'none' or rev == '' then
    return nil
  end
  if rev:match('^[#@]') then
    return file .. rev
  end
  return file .. '#' .. rev
end

--- Current content of the workspace file (its buffer when loaded).
---@param path string
---@return string[]
local function yours(path)
  local b = require('perforated.buffer').find(path)
  if b and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Write the merge result to the workspace file (through its buffer when loaded).
---@param path string
---@param lines string[]
local function write_result(path, lines)
  local b = require('perforated.buffer').find(path)
  if b and vim.api.nvim_buf_is_loaded(b) then
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.api.nvim_buf_call(b, function()
      vim.cmd('silent! write!')
    end)
  else
    vim.fn.writefile(lines, path)
  end
end

--- Merge one conflict with the tool.
---@param ws perforated.Workspace
---@param rec table  a `resolve -n -o` record
---@param tool string
---@param cb fun(ok: boolean, reason: string?)
local function merge_one(ws, rec, tool, cb)
  local path = rec.clientFile
  local base_spec = spec_of(rec.baseFile, rec.baseRev)
  local theirs_spec = spec_of(rec.fromFile, rec.endFromRev)
  if not theirs_spec then
    return cb(false, 'no "theirs" revision')
  end
  local p4 = require('perforated.p4')
  local got, base, theirs, err = 0, nil, nil, nil
  local function fetched()
    got = got + 1
    if got < 2 then
      return
    end
    if not base or not theirs then
      return cb(false, 'could not fetch revisions: ' .. tostring(err))
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local name = vim.fs.basename(path)
    local f = {
      base = dir .. '/' .. name .. '.base',
      theirs = dir .. '/' .. name .. '.theirs',
      merged = dir .. '/' .. name .. '.merged',
    }
    local mine = yours(path)
    vim.fn.writefile(base, f.base)
    vim.fn.writefile(theirs, f.theirs)
    vim.fn.writefile(mine, f.merged)
    local before = table.concat(mine, '\n')
    require('perforated.core.debug').log('info', 'resolve', 'merge tool for %s: %s', path, tool)
    require('perforated.tools').run(ws, tool, { f.base, f.theirs, path, f.merged }, function(code)
      local result = vim.fn.readfile(f.merged)
      vim.fn.delete(dir, 'rf')
      if code ~= 0 then
        return cb(false, ('merge tool exited with %d'):format(code))
      end
      if table.concat(result, '\n') == before then
        return cb(false, 'merge result unchanged (merge cancelled?)')
      end
      write_result(path, result)
      ws:run({ 'resolve', '-ay', p4.escape(path) }, {}, function(res)
        if #res.errors > 0 then
          return cb(false, res.errors[1])
        end
        cb(true)
      end)
    end)
  end
  if base_spec then
    p4.print(ws, base_spec, {}, function(l, e)
      base, err = l, err or e
      fetched()
    end)
  else
    base = {}
    fetched()
  end
  p4.print(ws, theirs_spec, {}, function(l, e)
    theirs, err = l, err or e
    fetched()
  end)
end

--- The result, centred, waiting for a key (vim.notify with `toast.backend = 'notify'`).
---@param lines string[]
---@param has_list boolean  files left in quickfix: offer to open it
---@param level integer
local function report(lines, has_list, level)
  if require('perforated.config').get().toast.backend == 'notify' then
    return vim.notify('[perforated] ' .. table.concat(lines, '\n'), level)
  end
  local items = { { key = '<CR>', label = 'OK', value = 'ok', aliases = { 'o' } } }
  if has_list then
    items[#items + 1] = { key = 'c', label = 'Open the quickfix list', value = 'list' }
  end
  local choice = require('perforated.ui.float').menu({
    title = 'Resolve',
    header = lines,
    header_hl = false,
    items = items,
    relative = 'editor',
  })
  if choice and choice.value == 'list' then
    vim.cmd('copen')
  end
end
M._report = report

--- Resolve files (nil = every file that needs it).
---@param ws perforated.Workspace
---@param paths string[]?
---@param cb fun(resolved: integer, left: integer)?
function M.run(ws, paths, cb)
  cb = cb or function() end
  local opts = paths
      and { globals = { '-x', '-' }, stdin = require('perforated.p4').escape_all(paths) }
    or {}
  local co = require('perforated.checkout')
  local jobs = require('perforated.jobs')
  local what = paths and #paths == 1 and vim.fn.fnamemodify(paths[1], ':t')
    or paths and ('%d files'):format(#paths)
    or 'workspace'
  local job, run_opts = jobs.start(ws, 'resolve ' .. what, { quiet = true })
  local toast = require('perforated.ui.toast')
  local unbusy = toast.busy(
    paths and ('Resolving %s…'):format(#paths == 1 and what or (#paths .. ' file(s)'))
      or 'Resolving every file that needs it…'
  )
  local function rel(path)
    if ws.root and path:sub(1, #ws.root + 1) == ws.root .. '/' then
      return path:sub(#ws.root + 2)
    end
    return path
  end
  ws:run({ 'resolve', '-am' }, vim.tbl_extend('force', opts, run_opts), function(res)
    if res.cancelled then
      unbusy()
      jobs.finish(job, 'resolve stopped', 'warn')
      toast.notify('[perforated] resolve stopped', vim.log.levels.WARN)
      co.changed(ws)
      return cb(0, 0)
    end
    if not res.ok and #res.records == 0 and #res.errors > 0 then
      unbusy()
      jobs.finish(job, 'resolve failed: ' .. res.errors[1], true)
      report({ 'Resolve failed:', '  ' .. vim.trim(res.errors[1]) }, false, vim.log.levels.ERROR)
      return cb(0, 0)
    end
    local attempted = {}
    for _, r in ipairs(res.records) do
      if r.clientFile then
        attempted[r.clientFile] = true
      end
    end
    ws:run(
      { 'resolve', '-n', '-o' },
      vim.tbl_extend('force', opts, { timeout = 0 }),
      function(pending)
        local conflicts = {}
        for _, r in ipairs(pending.records) do
          if r.clientFile then
            conflicts[#conflicts + 1] = r
          end
        end
        local auto = vim.tbl_count(attempted) - #conflicts
        local left = {} ---@type { path: string, reason: string, rec: table }[]
        local merged = 0
        local function finish()
          unbusy()
          local parts = {}
          if auto + merged > 0 then
            parts[#parts + 1] = ('resolved %d file(s)%s'):format(
              auto + merged,
              merged > 0 and (' (%d with the merge tool)'):format(merged) or ''
            )
          end
          if #left > 0 then
            parts[#parts + 1] = ('%d file(s) left unresolved (quickfix): %s'):format(
              #left,
              left[1].reason
            )
          end
          jobs.finish(
            job,
            #parts > 0 and table.concat(parts, '; ') or 'nothing to resolve',
            #left > 0 and 'warn' or nil
          )
          -- The result, centred: never silent (the quickfix list is easy to miss).
          local lines = {}
          if auto > 0 then
            lines[#lines + 1] = ('%d file(s) merged automatically'):format(auto)
          end
          if merged > 0 then
            lines[#lines + 1] = ('%d file(s) merged with your merge tool'):format(merged)
          end
          if #left > 0 then
            lines[#lines + 1] = ('%d file(s) left unresolved:'):format(#left)
            for k = 1, math.min(#left, 6) do
              lines[#lines + 1] = ('  %s  (%s)'):format(rel(left[k].path), left[k].reason)
            end
            if #left > 6 then
              lines[#lines + 1] = ('  … and %d more'):format(#left - 6)
            end
            lines[#lines + 1] = ''
            lines[#lines + 1] = 'They are in the quickfix list: R there resumes.'
          end
          if #lines == 0 then
            lines[1] = 'Nothing to resolve.'
          end
          if #left > 0 then
            local qf = require('perforated.ui.qf')
            local items = {}
            for _, l in ipairs(left) do
              items[#items + 1] = qf.item(l.path, 'unresolved: ' .. l.reason, {
                depotFile = l.rec.fromFile,
                kind = 'unresolved',
              })
            end
            qf.set({
              title = ('P4 resolve · %d file(s) left unresolved (R resumes)'):format(#left),
              kind = 'unresolved',
              items = items,
            })
          end
          co.changed(ws)
          -- p4 wrote merged content into the files: reload their (unmodified) buffers.
          require('perforated.ops').reload(ws, vim.tbl_keys(attempted))
          for _, b in ipairs(co.bufs_for(ws, vim.tbl_keys(attempted))) do
            require('perforated.buffer').refresh(b)
          end
          report(lines, #left > 0, #left > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
          cb(auto + merged, #left)
        end
        if #conflicts == 0 then
          return finish()
        end
        unbusy() -- the merge tool needs the screen
        require('perforated.tools').merge_tool(ws, function(tool)
          local i = 0
          local function step()
            i = i + 1
            local rec = conflicts[i]
            if not rec then
              return finish()
            end
            if rec.resolveType ~= 'content' then
              left[#left + 1] = {
                path = rec.clientFile,
                reason = (rec.resolveType or '?') .. ' resolve: use p4 resolve',
                rec = rec,
              }
              return step()
            end
            if not tool then
              left[#left + 1] = {
                path = rec.clientFile,
                reason = 'conflict; no merge tool (set P4MERGE or merge.tool)',
                rec = rec,
              }
              return step()
            end
            merge_one(ws, rec, tool, function(ok, reason)
              if ok then
                merged = merged + 1
              else
                left[#left + 1] = { path = rec.clientFile, reason = reason or '?', rec = rec }
              end
              step()
            end)
          end
          step()
        end)
      end
    )
  end)
end

return M
