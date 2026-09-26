--- "Are these two sides identical?" — checked before opening a diff, so identical files give
--- a message instead of an empty diff view. Cheap where it can be:
---
---   * depot revision vs depot revision: digests from one batched `fstat -Ol` (no content);
---   * an opened file vs its base, saved: one batched `p4 diff -sr` (p4 compares locally);
---   * anything else (unsaved buffers, a revision vs the workspace file): the contents.
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
    local b = vim.fn.bufnr(side.path)
    if b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
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

--- Check several pairs; `cb` gets a list of booleans (true = identical), in order.
---@param ws perforated.Workspace
---@param list { left: table, right: table }[]
---@param cb fun(same: boolean[])
function M.check(ws, list, cb)
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
    ws:run({ 'diff', '-sr' }, { globals = { '-x', '-' }, stdin = paths }, function(res)
      local same = {}
      for _, rec in ipairs(res.records) do
        if rec.clientFile then
          same[p4.key(ws, rec.clientFile)] = true
        end
      end
      for path, idxs in pairs(sr_paths) do
        for _, i in ipairs(idxs) do
          result[i] = same[p4.key(ws, path)] == true
        end
      end
      todo = todo - 1
      done()
    end)
  end

  for _, i in ipairs(content) do
    todo = todo + 1
    local got = {}
    local function side_lines(k, s)
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
      if s.lines then
        set(s.lines)
      elseif s.path then
        set(read(s.path))
      else
        p4.print(ws, s.spec, {}, function(lines)
          set(lines)
        end)
      end
    end
    side_lines(1, sides[i][1])
    side_lines(2, sides[i][2])
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
  M.check(ws, { { left = left, right = right } }, function(same)
    if same[1] then
      vim.notify(
        ('[perforated] identical: %s and %s'):format(label(left), label(right)),
        vim.log.levels.INFO
      )
    else
      open()
    end
  end)
end

return M
