--- Integrate / cherry-pick (`:P4 integrate [CL]`, `I` on a submitted changelist).
---
---   1. The source is the common directory of the changelist's files (`describe -s`).
---   2. The target is a path (`//depot/rel/...`) or a branch spec (`-b name`); the last
---      answer is remembered for the session. The first time, the client's stream is offered.
---      Relative paths line up: the source is cut to the target's depth (`source_root`).
---   3. Preview (`integrate -n`) → confirmation → `integrate -c <target CL>` → resolve (clean
---      merges are accepted; conflicts go to the merge tool).
---
--- Without a changelist, you're asked for a source path and pick one of its submitted
--- changelists.

local M = {}

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Longest common directory of depot paths (without the trailing slash).
---@param files string[]
---@return string?
function M.common_dir(files)
  local dir
  for _, f in ipairs(files) do
    local d = f:match('^(.*)/[^/]*$')
    if not dir then
      dir = d
    else
      while dir and d:sub(1, #dir + 1) ~= dir .. '/' and d ~= dir do
        dir = dir:match('^(.*)/[^/]*$')
      end
    end
  end
  if dir == '/' or dir == '' then
    return nil
  end
  return dir
end

--- Arguments for the integrate itself (target changelist and `-n` added by the caller).
---@param src string  source directory
---@param change string
---@param target string  a path, or '-b <branch>'
---@return string[]
local function integ_args(src, change, target)
  local branch = target:match('^%-b%s+(%S+)')
  if branch then
    return { '-b', branch, '-s', src .. '/...@=' .. change }
  end
  local tgt = target:gsub('/%.%.%.$', ''):gsub('/$', '')
  return { M.source_root(src, tgt) .. '/...@=' .. change, tgt .. '/...' }
end

--- The source directory matching a target path: the source cut to the target's depth, so
--- relative paths line up — files under `//stream1/app/src` integrated into `//stream2/...`
--- come from `//stream1/...` (`@=CL` keeps it to that changelist's files) and land in
--- `//stream2/app/src/…`, not at the top of `//stream2`. A target as deep as the source (or
--- deeper) takes the source as it is.
---@param src string  source directory (no trailing slash)
---@param tgt string  target directory (no trailing slash or `...`)
---@return string
function M.source_root(src, tgt)
  local depth = #vim.split(tgt:sub(3), '/', { plain = true })
  local parts = vim.split(src:sub(3), '/', { plain = true })
  if #parts <= depth then
    return src
  end
  return '//' .. table.concat(parts, '/', 1, depth)
end
M._integ_args = integ_args

--- The target offered first: the last answer this session, else the client's stream
--- (`//stream2/...`; relative paths are matched, see `source_root`). Nothing when the client
--- isn't a stream client or the source is in its stream.
---@param ws perforated.Workspace
---@param src string  source directory
---@return string
function M.default_target(ws, src)
  if ws.integrate_target then
    return ws.integrate_target
  end
  local stream = ws.info and ws.info.clientStream
  if not stream or stream == '' or M.source_root(src, stream) == stream then
    return ''
  end
  return stream .. '/...'
end

--- Preview, confirm, integrate, resolve.
---@param ws perforated.Workspace
---@param change string
---@param src string
---@param target string
---@param into string  target changelist
---@param cb fun(ok: boolean)
local function go(ws, change, src, target, into, cb)
  local qf = require('perforated.ui.qf')
  local args = integ_args(src, change, target)
  local cl_args = into == 'default' and {} or { '-c', into }
  ws:run(vim.list_extend(vim.list_extend({ 'integrate', '-n' }, cl_args), args), {}, function(res)
    local items = {}
    for _, r in ipairs(res.records) do
      if r.depotFile then
        items[#items + 1] = qf.item(
          r.clientFile or r.depotFile,
          ('%s ← %s'):format(r.action or '?', r.fromFile or '?'),
          {
            depotFile = r.depotFile,
            action = r.action,
            kind = 'integrate_preview',
          }
        )
      end
    end
    if #items == 0 then
      notify(
        'nothing to integrate: ' .. (res.errors[1] or res.warnings[1] or 'no files'),
        vim.log.levels.WARN
      )
      return cb(false)
    end
    qf.set({
      title = ('P4 integrate CL %s preview'):format(change),
      kind = 'integrate_preview',
      items = items,
    })
    local ok = require('perforated.ui.prompt').confirm(
      ('Integrate CL %s (%d file(s)) from %s into %s?'):format(
        change,
        #items,
        target:match('^%-b') and (src .. '/...') or (args[1]:gsub('@=.*$', '')),
        target
      ),
      '&Integrate\n&Cancel',
      2
    ) == 1
    if not ok then
      return cb(false)
    end
    ws:run(vim.list_extend(vim.list_extend({ 'integrate' }, cl_args), args), {}, function(done)
      local targets = {}
      for _, r in ipairs(done.records) do
        if r.clientFile then
          targets[#targets + 1] = r.clientFile
        end
      end
      if #done.errors > 0 and #targets == 0 then
        notify('integrate failed: ' .. done.errors[1], vim.log.levels.ERROR)
        return cb(false)
      end
      notify(('integrated %d file(s) from CL %s; resolving…'):format(#targets, change))
      require('perforated.checkout').changed(ws)
      require('perforated.resolve').run(ws, targets, function()
        cb(true)
      end)
    end)
  end)
end

--- Cherry-pick a submitted changelist into this workspace.
---@param ws perforated.Workspace
---@param change string?  nil = pick from a source path's submitted changelists
---@param cb fun(ok: boolean)?
function M.run(ws, change, cb)
  cb = cb or function() end
  if not change then
    return require('perforated.ui.prompt').input(
      { prompt = 'Integrate from (source path): ', default = ws.integrate_src or '' },
      function(src)
        if not src or vim.trim(src) == '' then
          return cb(false)
        end
        src = vim.trim(src):gsub('/%.%.%.$', ''):gsub('/$', '')
        ws.integrate_src = src .. '/...'
        require('perforated.changelists').submitted_changes(
          ws,
          { path = src .. '/...', max = 100 },
          function(changes, err)
            if not changes then
              notify(tostring(err), vim.log.levels.ERROR)
              return cb(false)
            end
            require('perforated.picker').pick({
              title = 'Integrate which changelist? · ' .. src,
              items = changes,
              format = function(c)
                return ('%-8s %-12s %s'):format(
                  c.change,
                  c.user or '',
                  vim.trim((c.desc or ''):match('[^\n]*') or '')
                )
              end,
              preview_buf = require('perforated.views.change_info').previewer(ws), -- the `K` popup
              on_choice = function(chosen)
                if chosen then
                  M.run(ws, chosen[1].change, cb)
                else
                  cb(false)
                end
              end,
            })
          end
        )
      end
    )
  end
  require('perforated.changelists').describe(ws, { change }, {}, function(by)
    local d = by[change]
    if not d or d.rec.status ~= 'submitted' then
      notify(('CL %s is not a submitted changelist'):format(change), vim.log.levels.ERROR)
      return cb(false)
    end
    local src = M.common_dir(vim.tbl_map(function(f)
      return f.depotFile
    end, d.files))
    if not src then
      notify('could not find a common source directory for CL ' .. change, vim.log.levels.ERROR)
      return cb(false)
    end
    require('perforated.ui.prompt').input({
      prompt = ('Integrate CL %s from %s/... into (path or -b branch): '):format(change, src),
      default = M.default_target(ws, src),
    }, function(target)
      if not target or vim.trim(target) == '' then
        return cb(false)
      end
      target = vim.trim(target)
      ws.integrate_target = target
      require('perforated.checkout_prompt').pick_change(ws, function(into, _, created)
        if not into then
          return cb(false)
        end
        go(ws, change, src, target, into, function(ok)
          if not ok and created then
            -- Made for this integrate, which didn't happen (cancelled at the preview, nothing
            -- to integrate, failed): don't leave an empty changelist behind.
            ws:run({ 'change', '-d', into }, {}, function()
              require('perforated.checkout').changed(ws)
              cb(false)
            end)
            return
          end
          cb(ok)
        end)
      end, {
        title = 'Open the integrated files in',
        copy_desc = { change = change, desc = d.rec.desc or '' },
      })
    end)
  end)
end

return M
