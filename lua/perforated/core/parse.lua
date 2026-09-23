--- Parsers for p4 output.
---
--- Primary format is `p4 -Mj -ztag` (one JSON object per line). Messages (errors, warnings,
--- info) are inline records carrying `severity` and `generic`; the exit code can be 0 even
--- when a record has severity >= 3, so callers must inspect records, not just the exit code.
---
--- A `-ztag` text parser with the same output shape exists as a fallback for old clients.

local M = {}

M.severity = { EMPTY = 0, INFO = 1, WARN = 2, FAILED = 3, FATAL = 4 }

---@param rec table
---@return boolean
function M.is_message(rec)
  if rec.severity ~= nil and rec.generic ~= nil then
    return true
  end
  -- Some commands (e.g. `status`) emit info messages as { data, level } only.
  return rec.level ~= nil and rec.data ~= nil and rec.depotFile == nil and rec.clientFile == nil
end

---@param rec table message record
---@return string
function M.message_text(rec)
  return (tostring(rec.data or ''):gsub('%s+$', ''))
end

--- Split a stream of p4 output into records and messages.
---@class perforated.Parsed
---@field records table[]   data records (non-message)
---@field warnings string[] severity <= 2 message texts (info + warnings)
---@field errors string[]   severity >= 3 message texts
---@field bad integer       lines that failed to decode

--- Decode a single JSON line. Returns nil for blank or undecodable lines.
---@param line string
---@return table?
function M.json_line(line)
  if line == '' or line:find('^%s*$') then
    return nil
  end
  local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(rec) == 'table' then
    return rec
  end
  return nil
end

--- Incremental line splitter for streamed stdout. Safe to call from fast (luv) callbacks.
---@param on_line fun(line: string)
---@return fun(chunk: string?) feed  call with nil at EOF to flush the remainder
function M.line_splitter(on_line)
  local rest = ''
  return function(chunk)
    if chunk == nil then
      if rest ~= '' then
        on_line(rest)
        rest = ''
      end
      return
    end
    local data = rest .. chunk
    local start = 1
    while true do
      local nl = data:find('\n', start, true)
      if not nl then
        break
      end
      on_line(data:sub(start, nl - 1))
      start = nl + 1
    end
    rest = data:sub(start)
  end
end

--- Classify decoded records into data records, warnings and errors.
---@param recs table[]
---@param bad integer?
---@return perforated.Parsed
function M.classify(recs, bad)
  local out = { records = {}, warnings = {}, errors = {}, bad = bad or 0 }
  for _, rec in ipairs(recs) do
    if M.is_message(rec) then
      local sev = tonumber(rec.severity) or tonumber(rec.level) or 0
      if sev >= M.severity.FAILED then
        out.errors[#out.errors + 1] = M.message_text(rec)
      else
        out.warnings[#out.warnings + 1] = M.message_text(rec)
      end
    else
      out.records[#out.records + 1] = rec
    end
  end
  return out
end

--- Parse full `-Mj -ztag` output.
---@param text string
---@return perforated.Parsed
function M.jsonl(text)
  local recs, bad = {}, 0
  local split = M.line_splitter(function(line)
    local rec = M.json_line(line)
    if rec then
      recs[#recs + 1] = rec
    elseif not line:find('^%s*$') then
      bad = bad + 1
    end
  end)
  split(text)
  split(nil)
  return M.classify(recs, bad)
end

--- Parse plain `-ztag` text output (fallback when -Mj is unavailable).
--- Records are blocks of `... key value` lines separated by blank lines; continuation lines
--- (multi-line values such as descriptions) are appended to the previous field.
---@param text string
---@return perforated.Parsed
function M.ztag(text)
  local recs = {}
  local cur, last_key
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    local key, val = line:match('^%.%.%. (%S+) ?(.*)$')
    if key then
      cur = cur or {}
      cur[key] = val
      last_key = key
    elseif line == '' then
      if cur then
        recs[#recs + 1] = cur
      end
      cur, last_key = nil, nil
    elseif cur and last_key then
      cur[last_key] = cur[last_key] .. '\n' .. line
    else
      -- Untagged text (e.g. messages) → treat as info message.
      recs[#recs + 1] = { data = line, severity = 1, generic = 0 }
    end
  end
  if cur then
    recs[#recs + 1] = cur
  end
  return M.classify(recs)
end

--- Unfold indexed fields (`rev0, change0, rev1, …` and `how0,0, file0,1, …`) into arrays.
---
---   indexed({ rev0='3', change0='12', rev1='2', change1='9' }, { 'rev', 'change' })
---   --> { { rev='3', change='12' }, { rev='2', change='9' } }
---
--- Two-level fields (`how0,1`) land in `items[i].sub[j]`.
---@param rec table
---@param names string[]? restrict to these base names (recommended); nil = any `%a+%d+` key
---@return table[]
function M.indexed(rec, names)
  local allow
  if names then
    allow = {}
    for _, n in ipairs(names) do
      allow[n] = true
    end
  end
  local items = {}
  for k, v in pairs(rec) do
    if type(k) == 'string' then
      local base, i, j = k:match('^(%a+)(%d+),(%d+)$')
      if not base then
        base, i = k:match('^(%a+)(%d+)$')
      end
      if base and (not allow or allow[base]) then
        i = tonumber(i) + 1
        local item = items[i]
        if not item then
          item = {}
          items[i] = item
        end
        if j then
          j = tonumber(j) + 1
          item.sub = item.sub or {}
          item.sub[j] = item.sub[j] or {}
          item.sub[j][base] = v
        else
          item[base] = v
        end
      end
    end
  end
  -- Compact: indices are dense in p4 output, but be defensive.
  local out = {}
  for i = 1, table.maxn(items) do
    if items[i] then
      out[#out + 1] = items[i]
    end
  end
  return out
end

--- Parse `p4 set` (untagged) output:
---   P4PORT=1666 (config '/path/.p4config')
---   P4USER=bob            ← environment
---   P4EDITOR=vim (set)    ← P4ENVIRO / registry
---@param text string
---@return table<string, {value: string, source: string, path: string?}>
function M.p4set(text)
  local out = {}
  for line in text:gmatch('[^\r\n]+') do
    local name, rest = line:match('^([%w_]+)=(.*)$')
    if name then
      local value, src = rest:match('^(.-) %((.-)%s*%)$')
      if not value then
        value, src = rest, 'environment'
      end
      local path = src:match("^config '(.-)'$")
      local source = path and 'config' or src
      out[name] = { value = value, source = source, path = path }
    end
  end
  return out
end

return M
