--- Check-out / add prompt and changelist choice (loaded on first use).
---
--- Split from checkout.lua so the activation path doesn't carry the prompt UI.

local p4 = require('perforated.p4')
local config = require('perforated.config')
local dbg = require('perforated.core.debug')
local co = require('perforated.checkout')

local M = {}

local function notify(msg, level)
  vim.notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

---@param ws perforated.Workspace
---@return string label for the sticky/default target
local function target_label(ws)
  if ws.sticky_cl and ws.sticky_cl ~= 'default' then
    local desc = ws.sticky_desc and vim.trim(ws.sticky_desc:match('[^\n]*') or '') or ''
    return ('CL %s%s'):format(ws.sticky_cl, desc ~= '' and (' "' .. desc .. '"') or '')
  end
  return 'default changelist'
end

---@param ws perforated.Workspace
---@param cl string?
---@param desc string?
local function set_sticky(ws, cl, desc)
  if config.get().checkout.sticky then
    ws.sticky_cl = cl
    ws.sticky_desc = desc
  end
end

--- Pick a pending changelist, or create a new one (any installed picker).
---@param ws perforated.Workspace
---@param cb fun(cl: string?, desc: string?)
function M.pick_change(ws, cb)
  p4.pending_changes(ws, function(changes, err)
    if not changes then
      notify('could not list changelists: ' .. tostring(err), vim.log.levels.ERROR)
      return cb(nil)
    end
    local items = { { change = 'default', desc = '' } }
    vim.list_extend(items, changes)
    items[#items + 1] = { change = 'new', desc = '' }
    require('perforated.picker').pick({
      title = 'Changelist',
      items = items,
      format = function(c)
        if c.change == 'default' then
          return 'default'
        elseif c.change == 'new' then
          return '+ new changelist…'
        end
        return ('%-8s %s'):format(c.change, vim.trim((c.desc or ''):match('[^\n]*') or ''))
      end,
      preview = function(c)
        if c.change == 'default' or c.change == 'new' then
          return {}
        end
        return vim.split(c.desc or '', '\n', { plain = true })
      end,
      on_choice = function(chosen)
        local choice = chosen and chosen[1]
        if not choice then
          return cb(nil)
        end
        if choice.change == 'new' then
          return M.new_change(ws, cb)
        end
        cb(choice.change, choice.desc)
      end,
    })
  end)
end

--- Create a new changelist from a description entered in the editor float.
---@param ws perforated.Workspace
---@param cb fun(cl: string?, desc: string?)
function M.new_change(ws, cb)
  -- Multi-line description editor (float); cancelling calls cb(nil).
  require('perforated.views.change_editor').new(ws, { on_done = cb })
end

--- Show the check-out/add menu for a buffer and act on the choice.
---@param buf integer
---@param verb 'edit'|'add'
function M.prompt(buf, verb)
  local st = require('perforated.buffer').get(buf)
  if not st then
    return
  end
  local c = co._state(buf)
  if c.prompting then
    return
  end
  local ws = st.ws
  local op = verb == 'edit' and co.edit or co.add
  local function run(cl, desc)
    if cl then
      set_sticky(ws, cl, desc)
    end
    op(ws, { st.path }, cl or ws.sticky_cl)
  end

  if co._session.auto then
    return run(nil)
  end

  -- Refresh the pending list meanwhile: a sticky CL that was submitted/deleted is dropped.
  if ws.sticky_cl and ws.sticky_cl ~= 'default' then
    p4.pending_changes(ws, function(changes)
      if not changes then
        return
      end
      for _, ch in ipairs(changes) do
        if ch.change == ws.sticky_cl then
          ws.sticky_desc = ch.desc
          return
        end
      end
      ws.sticky_cl, ws.sticky_desc = nil, nil
    end)
  end

  local rec = st.rec or {}
  local name = vim.fn.fnamemodify(st.path, ':~:.')
  local header = {}
  if verb == 'edit' then
    header[1] = ('%s  #%s/#%s'):format(name, rec.haveRev or '?', rec.headRev or '?')
    if require('perforated.status').is_stale(rec) then
      header[#header + 1] = ('%s newer revision in depot (#%s) — sync before submit'):format(
        require('perforated.ui.icons').glyph('stale'),
        rec.headRev
      )
    end
    if rec.otherOpen then
      header[#header + 1] = 'also opened by another user'
    end
  else
    header[1] = name .. '  (not in depot)'
  end
  local action = verb == 'edit' and 'Check out' or 'Add'
  local function not_now()
    if verb == 'edit' and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].readonly = true -- honest: the file is still not checked out
    end
    notify(
      ('%s cancelled: %s is not %s'):format(
        verb == 'edit' and 'check-out' or 'add',
        vim.fn.fnamemodify(st.path, ':t'),
        verb == 'edit' and 'checked out' or 'added'
      ),
      vim.log.levels.WARN
    )
  end
  c.prompting = true
  local choice, replay = require('perforated.ui.float').menu({
    title = verb == 'edit' and 'Perforce: check out?' or 'Perforce: add?',
    header = header,
    grace = config.get().checkout.prompt_grace,
    items = {
      { key = '<CR>', label = ('%s to %s'):format(action, target_label(ws)), value = 'sticky' },
      { key = 'c', label = 'choose changelist…', value = 'pick' },
      { key = 'n', label = 'new changelist…', value = 'new' },
      { key = 'A', label = 'always use this target (session, no prompt)', value = 'auto' },
      { key = 's', label = 'skip (this buffer)', value = 'skip' },
      { key = 'S', label = 'never ask (this session)', value = 'never' },
    },
  })
  c.prompting = false
  local v = choice and choice.value or 'dismiss' -- <Esc>/q: not now (only `s` skips the buffer)
  dbg.info(
    'checkout',
    'buf %d %s prompt: choice=%s replayed=%d key(s) sticky=%s',
    buf,
    verb,
    v,
    #replay,
    tostring(ws.sticky_cl)
  )
  if v == 'sticky' then
    run(nil)
  elseif v == 'pick' or v == 'new' then
    -- Cancelling the picker / description input is "not now", not "skip this buffer": the
    -- file stays unopened and read-only, and the prompt comes back (after :e!, or via
    -- <leader>pe / :P4 edit).
    local function done(cl, desc)
      if cl then
        run(cl, desc)
      else
        dbg.info('checkout', 'buf %d %s: target selection cancelled', buf, verb)
        not_now()
      end
    end
    if v == 'pick' then
      M.pick_change(ws, done)
    else
      M.new_change(ws, done)
    end
  elseif v == 'auto' then
    co._session.auto = true
    run(nil)
  elseif v == 'dismiss' then
    not_now()
  else
    c.skip = true
    if v == 'never' then
      co._session.never = true
    end
    if verb == 'edit' and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].readonly = true -- honest: the file is still not checked out
    end
  end
  require('perforated.ui.float').replay(replay)
end

return M
