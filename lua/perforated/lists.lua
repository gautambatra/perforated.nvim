--- List producers that feed the quickfix/location list: opened files, stale/unresolved
--- files, and hunks (per file or across every opened file).

local p4 = require('perforated.p4')
local qf = require('perforated.ui.qf')
local engine = require('perforated.diff.engine')

local M = {}

---@param rec table
---@return string
local function revs(rec)
  return ('#%s/#%s'):format(rec.haveRev or '-', rec.headRev or '-')
end

local function first_line(s)
  return vim.trim((s or ''):match('[^\n]*') or '')
end

--- Opened files grouped by changelist.
---@param ws perforated.Workspace
---@param cb fun(items: table[])
function M.opened_items(ws, cb)
  local recs, changes, modified
  local function done()
    if not recs or not changes or modified == nil then
      return
    end
    local mod = require('perforated.modified')
    local overlay = mod.overlay(ws)
    local desc = { default = '' }
    for _, c in ipairs(changes) do
      desc[c.change] = first_line(c.desc)
    end
    local groups, order = {}, {}
    for _, r in ipairs(recs) do
      local cl = r.change or 'default'
      if not groups[cl] then
        groups[cl] = {}
        order[#order + 1] = cl
      end
      table.insert(groups[cl], r)
    end
    table.sort(order, function(a, b)
      if a == 'default' then
        return true
      elseif b == 'default' then
        return false
      end
      return tonumber(a) < tonumber(b)
    end)
    local items = {}
    for _, cl in ipairs(order) do
      local files = groups[cl]
      table.sort(files, function(a, b)
        return a.clientFile < b.clientFile
      end)
      local head = cl == 'default' and 'default changelist'
        or ('CL %s  %s'):format(cl, desc[cl] or '')
      items[#items + 1] = qf.header(('── %s (%d)'):format(head, #files))
      for _, r in ipairs(files) do
        local flags = {}
        if require('perforated.status').is_stale(r) then
          flags[#flags + 1] = 'STALE'
        end
        if r.unresolved then
          flags[#flags + 1] = 'UNRESOLVED'
        end
        -- ● changed / · unchanged (dimmed by the qf window's syntax, see ui/qf.lua)
        local changed = mod.is_changed(ws, r, modified or nil, overlay)
        local mark = changed == true and (require('perforated.ui.icons').glyph('modified') .. ' ')
          or changed == false and '· '
          or ''
        items[#items + 1] = qf.item(
          r.clientFile,
          ('%s%-10s %s %s'):format(mark, r.action, revs(r), table.concat(flags, ' ')),
          { depotFile = r.depotFile, change = cl, action = r.action, kind = 'opened' }
        )
      end
    end
    cb(items)
  end
  p4.fstat_opened(ws, {}, function(r)
    recs = r or {}
    done()
  end)
  p4.pending_changes(ws, function(c)
    changes = c or {}
    done()
  end)
  require('perforated.modified').query(ws, nil, function(set)
    modified = set or false
    done()
  end)
end

--- Opened files that are stale (have < head) or unresolved.
---@param ws perforated.Workspace
---@param cb fun(items: table[])
function M.status_items(ws, cb)
  p4.fstat_opened(ws, {}, function(recs)
    local items = {}
    for _, r in ipairs(recs or {}) do
      local why = {}
      if require('perforated.status').is_stale(r) then
        why[#why + 1] = ('stale %s → sync before submit'):format(revs(r))
      end
      if r.unresolved then
        why[#why + 1] = 'unresolved → :P4 resolve'
      end
      if #why > 0 then
        items[#items + 1] = qf.item(
          r.clientFile,
          table.concat(why, '; '),
          { depotFile = r.depotFile, change = r.change, action = r.action, kind = 'status' }
        )
      end
    end
    cb(items)
  end)
end

---@param path string
---@param hunks perforated.Hunk[]
---@param base string[]
---@param cur string[]
---@param bufnr integer?
---@return table[]
local function hunk_items(path, hunks, base, cur, bufnr)
  local items = {}
  for _, h in ipairs(hunks) do
    local top = engine.range(h)
    local sample
    if h.type == 'delete' then
      sample = '- ' .. vim.trim(base[h.a_start] or '')
    else
      sample = '+ ' .. vim.trim(cur[h.b_start] or '')
    end
    items[#items + 1] = {
      filename = bufnr and nil or path,
      bufnr = bufnr,
      lnum = top,
      col = 1,
      text = ('%-6s +%d -%d  %s'):format(
        h.type,
        h.type == 'delete' and 0 or h.b_count,
        h.a_count,
        sample
      ),
      user_data = { kind = 'hunk', type = h.type },
    }
  end
  return items
end

--- Hunks of one buffer.
---@param buf integer
---@return table[]
function M.buffer_hunk_items(buf)
  local st = require('perforated.buffer').get(buf)
  if not st or not st.base then
    return {}
  end
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return hunk_items(st.path, st.hunks, st.base, cur, buf)
end

--- Hunks across every opened file: one fstat, one batched print for uncached bases, then
--- in-process diffs (loaded buffers use their current text; others are read from disk).
---@param ws perforated.Workspace
---@param cb fun(items: table[])
function M.all_hunk_items(ws, cb)
  p4.fstat_opened(ws, {}, function(recs)
    recs = vim.tbl_filter(function(r)
      return p4.is_text(r) and r.action ~= 'delete' and r.action ~= 'move/delete'
    end, recs or {})
    table.sort(recs, function(a, b)
      return a.clientFile < b.clientFile
    end)
    local cache = require('perforated.core.cache').content()
    local need = {}
    for _, r in ipairs(recs) do
      local spec = p4.base_spec(r)
      if spec and not cache:has(ws:server_key() .. '|' .. spec) then
        need[#need + 1] = spec
      end
    end
    local function finish(fetched)
      local items = {}
      local loaded = {}
      for b, st in pairs(require('perforated.buffer').all()) do
        if st.ws == ws then
          loaded[st.key] = b
        end
      end
      for _, r in ipairs(recs) do
        local spec = p4.base_spec(r)
        local base = {}
        if spec then
          local k = ws:server_key() .. '|' .. spec
          base = cache:get(k) or fetched[spec]
          if fetched[spec] then
            cache:set(k, fetched[spec], 40 * #fetched[spec])
          end
        end
        if base then
          local b = loaded[p4.key(ws, r.clientFile)]
          local cur
          if b and vim.api.nvim_buf_is_loaded(b) then
            cur = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          else
            local fd = io.open(r.clientFile, 'rb')
            cur = fd and p4.split_lines(fd:read('*a')) or {}
            if fd then
              fd:close()
            end
          end
          vim.list_extend(items, hunk_items(r.clientFile, engine.hunks(base, cur), base, cur, b))
        end
      end
      cb(items)
    end
    if #need == 0 then
      return finish({})
    end
    p4.print_many(ws, need, {}, finish)
  end)
end

return M
