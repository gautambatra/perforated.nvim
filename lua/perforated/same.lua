--- "Are these two sides identical?" — checked before opening a diff, so identical files give
--- a message instead of an empty diff view. Cheap where it can be:
---
---   * depot revision vs depot revision: digests from one batched `fstat -Ol` (no content);
---   * an opened file vs its base, saved: one batched `p4 diff -sr` (p4 compares locally);
---   * anything else (unsaved buffers, a revision vs the workspace file): the contents, the
---     depot sides printed together (`p4.print_batch`, 50 a call).
---
--- Sides are diff sides: { spec = … } | { path = … } | { buf = … } | { empty = … }.

local p4 = require('perforated.p4')

local M = {}

---@param side table
---@return table  normalised: { spec } | { path } | { lines } | { empty }
local function norm(side)
  if side.buf then
    if vim.api.nvim_buf_is_valid(side.buf) and vim.api.nvim_buf_is_loaded(side.buf) then
      if vim.bo[side.buf].modified or vim.bo[side.buf].buftype ~= '' then
        return { lines = vim.api.nvim_buf_get_lines(side.buf, 0, -1, false) }
      end
      return { path = vim.api.nvim_buf_get_name(side.buf) }
    end
    return { empty = true }
  end
  if side.path then
    local b = require('perforated.buffer').find(side.path)
    if b and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      return { lines = vim.api.nvim_buf_get_lines(b, 0, -1, false) }
    end
    return { path = side.path }
  end
  if side.spec then
    return { spec = side.spec }
  end
  return { empty = true }
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- How many depot files one content-comparison `print` asks for.
M.BATCH = 50

--- Check several pairs; `cb` gets a list of booleans (true = identical), in order.
--- `opts.snapshot` (a diff tab's) keeps the content printed for comparisons, up to
--- `opts.keep_kb` in all, so showing those files needs no print; `opts.alone`: specs printed by
--- themselves (already being printed: the tab's first file), not in a batch.
---@param ws perforated.Workspace
---@param list { left: table, right: table }[]
---@param cb fun(same: boolean[])
---@param opts { snapshot: perforated.Snapshot?, keep_kb: integer?, alone: table<string, true>? }?
function M.check(ws, list, cb, opts)
  opts = opts or {}
  local t0 = vim.uv.hrtime()
  local result = {}
  local digest_specs, digest_seen = {}, {}
  local sr_paths = {} -- path → { pair indexes } for `diff -sr`
  local content = {} -- pair indexes compared by content
  local todo = 1 -- held until every comparison has been queued
  local finished = false
  local function done()
    if todo == 0 and not finished then
      finished = true
      vim.schedule(function()
        require('perforated.core.debug').timing(
          'identical-files check',
          (vim.uv.hrtime() - t0) / 1e6
        )
        cb(result)
      end)
    end
  end

  local sides = {}
  for i, pr in ipairs(list) do
    local l, r = norm(pr.left), norm(pr.right)
    sides[i] = { l, r }
    if l.empty and r.empty then
      result[i] = true
    elseif l.empty or r.empty then
      result[i] = false
    elseif l.spec and r.spec then
      for _, s in ipairs({ l.spec, r.spec }) do
        if not digest_seen[s] then
          digest_seen[s] = true
          digest_specs[#digest_specs + 1] = s
        end
      end
    else
      -- A saved workspace file against its opened file's base: let p4 compare.
      local spec, path = l.spec or r.spec, l.path or r.path
      local rec = path and ws.fstat and ws.fstat[p4.key(ws, path)]
      if spec and path and rec and rec.action and p4.base_spec(rec) == spec then
        sr_paths[path] = sr_paths[path] or {}
        table.insert(sr_paths[path], i)
      else
        content[#content + 1] = i
      end
    end
  end

  if #digest_specs > 0 then
    todo = todo + 1
    ws:run(
      { 'fstat', '-Ol', '-T', 'depotFile,digest,fileSize' },
      { globals = { '-x', '-' }, stdin = digest_specs },
      function(res)
        -- Records and "no such file" messages come back in input order.
        local digest, n = {}, 0
        for _, rec in ipairs(res.all or {}) do
          if rec.depotFile or rec.severity or rec.level then
            n = n + 1
            local s = digest_specs[n]
            if s and rec.digest then
              digest[s] = rec.digest .. ':' .. (rec.fileSize or '')
            end
          end
        end
        for i, sd in ipairs(sides) do
          if result[i] == nil and sd[1].spec and sd[2].spec then
            local a, b = digest[sd[1].spec], digest[sd[2].spec]
            result[i] = a ~= nil and a == b
          end
        end
        todo = todo - 1
        done()
      end
    )
  end

  local paths = vim.tbl_keys(sr_paths)
  if #paths > 0 then
    todo = todo + 1
    -- The workspace's marker cache answers files untouched since their last comparison; one
    -- `diff -sr` the rest, and its answers go to the cache.
    local mod = require('perforated.modified')
    local recs = {}
    for _, path in ipairs(paths) do
      recs[path] = ws.fstat[p4.key(ws, path)]
    end
    mod.valid(ws, vim.tbl_values(recs), function(valid, stats)
      local ask = {}
      for path, idxs in pairs(sr_paths) do
        local changed = valid[p4.key(ws, path)]
        if changed ~= nil then
          for _, i in ipairs(idxs) do
            result[i] = not changed
          end
        else
          ask[#ask + 1] = path
        end
      end
      if #ask == 0 then
        todo = todo - 1
        return done()
      end
      table.sort(ask)
      local run_opts = { globals = { '-x', '-' }, stdin = p4.escape_all(ask) }
      ws:run({ 'diff', '-sr' }, run_opts, function(res)
        local same = {}
        for _, rec in ipairs(res.records) do
          if rec.clientFile then
            same[p4.key(ws, rec.clientFile)] = true
          end
        end
        local answered = res.ok or #res.records > 0
        for _, path in ipairs(ask) do
          local k = p4.key(ws, path)
          for _, i in ipairs(sr_paths[path]) do
            result[i] = same[k] == true
          end
          if answered and stats[k] ~= nil then
            mod.store(ws, recs[path], not same[k], stats[k])
          end
        end
        todo = todo - 1
        done()
      end)
    end)
  end

  -- Content comparisons: local sides read here, depot sides printed (together where they can).
  local wanted, waiting = {}, {} -- specs to print; spec → fns for its lines
  for _, i in ipairs(content) do
    todo = todo + 1
    local got = {}
    for k = 1, 2 do
      local function set(lines)
        got[k] = lines or false
        if got[1] ~= nil and got[2] ~= nil then
          result[i] = got[1] ~= false
            and got[2] ~= false
            and #got[1] == #got[2]
            and table.concat(got[1], '\n') == table.concat(got[2], '\n')
          todo = todo - 1
          done()
        end
      end
      local s = sides[i][k]
      if s.lines then
        set(s.lines)
      elseif s.path then
        set(read(s.path))
      else
        if not waiting[s.spec] then
          waiting[s.spec] = {}
          wanted[#wanted + 1] = s.spec
        end
        table.insert(waiting[s.spec], set)
      end
    end
  end
  local function answer(spec, lines)
    for _, fn in ipairs(waiting[spec]) do
      fn(lines)
    end
  end
  local batch, budget = {}, opts.keep_kb and { bytes = opts.keep_kb * 1024 } or nil
  for _, spec in ipairs(wanted) do
    if opts.alone and opts.alone[spec] or #wanted == 1 then
      p4.print(ws, spec, { snapshot = opts.snapshot }, function(lines)
        answer(spec, lines)
      end)
    else
      batch[#batch + 1] = spec
    end
  end
  for first = 1, #batch, M.BATCH do
    local chunk = vim.list_slice(batch, first, first + M.BATCH - 1)
    p4.print_batch(ws, chunk, { snapshot = opts.snapshot, budget = budget }, function(got)
      for _, spec in ipairs(chunk) do
        answer(spec, got[spec])
      end
    end)
  end

  todo = todo - 1
  done()
end

--- Label of a side for messages.
local function label(side)
  if side.spec then
    return side.spec
  end
  local path = side.path or (side.buf and vim.api.nvim_buf_get_name(side.buf)) or ''
  return vim.fn.fnamemodify(path, ':~:.')
end

--- Open a diff only when the sides differ; otherwise say they're identical.
---@param ws perforated.Workspace
---@param left table
---@param right table
---@param open fun()
function M.or_open(ws, left, right, open)
  local view = require('perforated.diff.view')
  view.start_busy() -- "Opening diff view…" (closed by the diff view, once it has its content)
  M.check(ws, { { left = left, right = right } }, function(same)
    if same[1] then
      view.finish_busy()
      require('perforated.ui.toast').show(
        'Perforce: identical, nothing to diff',
        { label(left), label(right) },
        vim.log.levels.INFO
      )
    else
      open()
    end
  end)
end

return M
