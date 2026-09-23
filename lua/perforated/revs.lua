--- Helpers shared by the M3 views for "sides" of a comparison: a depot revision, a workspace
--- file or nothing.
---
---   { spec = '//depot/a.c#3' }   { path = '/ws/a.c' }   { empty = 'added' }

local M = {}

---@class perforated.RevSide
---@field spec string?
---@field path string?
---@field empty string?

--- Content of a side, as lines.
---@param ws perforated.Workspace
---@param side perforated.RevSide
---@param cb fun(lines: string[]?, err: string?)
function M.lines(ws, side, cb)
  if side.spec then
    return require('perforated.p4').print(ws, side.spec, {}, cb)
  end
  vim.schedule(function()
    if side.path then
      local b = vim.fn.bufnr(side.path)
      if b > 0 and vim.api.nvim_buf_is_loaded(b) then
        return cb(vim.api.nvim_buf_get_lines(b, 0, -1, false))
      end
      local ok, lines = pcall(vim.fn.readfile, side.path)
      if not ok then
        return cb(nil, 'cannot read ' .. side.path)
      end
      return cb(lines)
    end
    cb({})
  end)
end

--- Convert to a diff.view side.
---@param side perforated.RevSide
---@return perforated.DiffSide
local function diff_side(side)
  if side.path then
    local b = vim.fn.bufadd(side.path)
    vim.fn.bufload(b)
    return { buf = b }
  end
  return { spec = side.spec, empty = side.empty }
end

--- Side-by-side diff in a new tab.
---@param ws perforated.Workspace
---@param left perforated.RevSide
---@param right perforated.RevSide
function M.diff(ws, left, right)
  local label = left.spec or right.spec or right.path
  require('perforated.diff.view').pair(ws, diff_side(left), diff_side(right), {
    spec = left.spec,
    path = right.path or (label and label:gsub('[#@].*$', '')),
  })
end

--- Open a depot revision read-only (or a workspace file) in a new tab, at a line.
---@param ws perforated.Workspace
---@param side perforated.RevSide
---@param lnum integer?
function M.open(ws, side, lnum)
  if side.path then
    vim.cmd('tabedit ' .. vim.fn.fnameescape(side.path))
  elseif side.spec then
    local buf = require('perforated.uri').buffer(ws, side.spec)
    vim.cmd('tab sbuffer ' .. buf)
  else
    return
  end
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

--- Workspace paths of depot files (one `p4 where` call); unmapped files are absent.
---@param ws perforated.Workspace
---@param depot_files string[]
---@param cb fun(map: table<string, string>)
function M.where(ws, depot_files, cb)
  if ws.mode == 'connection' or #depot_files == 0 then
    return vim.schedule(function()
      cb({})
    end)
  end
  ws:run({ 'where' }, { globals = { '-x', '-' }, stdin = depot_files }, function(res)
    local map = {}
    for _, r in ipairs(res.records) do
      if r.depotFile and r.path and not r.unmap then
        map[r.depotFile] = r.path
      end
    end
    cb(map)
  end)
end

--- Unified-diff lines between two sides, computed in-process.
---@param a string[]
---@param b string[]
---@return string[]
function M.unified(a, b)
  local ta = #a > 0 and (table.concat(a, '\n') .. '\n') or ''
  local tb = #b > 0 and (table.concat(b, '\n') .. '\n') or ''
  local algorithm = require('perforated.config').get().signs.algorithm
  local difffn = (vim.text and vim.text.diff) or vim.diff -- vim.diff is deprecated in 0.12+
  local out = difffn(ta, tb, { ctxlen = 3, algorithm = algorithm }) --[[@as string]]
  local lines = vim.split(out or '', '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

return M
