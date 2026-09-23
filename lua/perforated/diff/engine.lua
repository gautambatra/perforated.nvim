--- In-process diff (never `p4 diff`): base text from `p4 print`, working text from the buffer.
--- Large inputs are diffed on a libuv worker thread so the UI never blocks.

local M = {}

local diff = (vim.text and vim.text.diff) or vim.diff

--- Sign diffs use myers + indent heuristic: ~5x faster than histogram on large files, and
--- linematch (which doubles the cost) only matters for word-level diffs, not gutter signs.
M.OPTS = { result_type = 'indices', algorithm = 'myers', indent_heuristic = true }

local function opts()
  local alg = require('perforated.config').get().signs.algorithm
  if alg and alg ~= M.OPTS.algorithm then
    return vim.tbl_extend('force', M.OPTS, { algorithm = alg })
  end
  return M.OPTS
end

---@class perforated.Hunk
---@field type 'add'|'change'|'delete'
---@field a_start integer  first base line (for delete/change); line after which lines were added
---@field a_count integer
---@field b_start integer  first buffer line (add/change); line after which lines were deleted
---@field b_count integer

---@param idx integer[][]
---@return perforated.Hunk[]
local function to_hunks(idx)
  local hunks = {}
  for i, h in ipairs(idx) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    local t = a_count == 0 and 'add' or (b_count == 0 and 'delete' or 'change')
    hunks[i] =
      { type = t, a_start = a_start, a_count = a_count, b_start = b_start, b_count = b_count }
  end
  return hunks
end

---@param lines string[]
---@return string
local function join(lines)
  if #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n') .. '\n'
end
M.join = join

--- Synchronous diff. `base` may be pre-joined text (cached per buffer: it never changes).
---@param base string[]|string
---@param cur string[]
---@return perforated.Hunk[]
function M.hunks(base, cur)
  local a = type(base) == 'string' and base or join(base)
  return to_hunks(diff(a, join(cur), opts()) --[[@as integer[][] ]])
end

--- Diff on a worker thread; `cb` runs on the main loop. Inputs are passed as strings (only
--- strings/numbers cross the thread boundary), the result comes back encoded.
---@param base string[]|string
---@param cur string[]
---@param cb fun(hunks: perforated.Hunk[])
function M.hunks_async(base, cur, cb)
  local ok = pcall(function()
    local work = vim.uv.new_work(function(a, b, algorithm)
      local difffn = (vim.text and vim.text.diff) or vim.diff -- vim.diff is deprecated in 0.12+
      local r = difffn(a, b, {
        result_type = 'indices',
        algorithm = algorithm,
        indent_heuristic = true,
      })
      local parts = {}
      for i, h in ipairs(r) do
        parts[i] = h[1] .. ',' .. h[2] .. ',' .. h[3] .. ',' .. h[4]
      end
      return table.concat(parts, ';')
    end, function(encoded)
      local idx = {}
      for hunk in encoded:gmatch('[^;]+') do
        local a, b, c, d = hunk:match('^(%d+),(%d+),(%d+),(%d+)$')
        idx[#idx + 1] = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
      end
      vim.schedule(function()
        cb(to_hunks(idx))
      end)
    end)
    work:queue(type(base) == 'string' and base or join(base), join(cur), opts().algorithm)
  end)
  if not ok then
    -- Threads unavailable: fall back to a synchronous diff on the next tick.
    vim.schedule(function()
      cb(M.hunks(base, cur))
    end)
  end
end

--- Count added/changed/removed lines (gitsigns-style summary).
---@param hunks perforated.Hunk[]
---@return { added: integer, changed: integer, removed: integer }
function M.summary(hunks)
  local s = { added = 0, changed = 0, removed = 0 }
  for _, h in ipairs(hunks) do
    if h.type == 'add' then
      s.added = s.added + h.b_count
    elseif h.type == 'delete' then
      s.removed = s.removed + h.a_count
    else
      local common = math.min(h.a_count, h.b_count)
      s.changed = s.changed + common
      s.added = s.added + (h.b_count - common)
      s.removed = s.removed + (h.a_count - common)
    end
  end
  return s
end

--- First and last buffer line a hunk covers (deletions sit on the line above, min 1).
---@param h perforated.Hunk
---@return integer top, integer bottom
function M.range(h)
  if h.type == 'delete' then
    local l = math.max(h.b_start, 1)
    return l, l
  end
  return h.b_start, h.b_start + h.b_count - 1
end

return M
