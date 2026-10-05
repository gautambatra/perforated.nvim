--- Changelist description editor.
---
--- Quick mode: a float holding only the description. `:w` / `<C-s>` saves, `q` / `<Esc>`
--- cancels (asking when modified), `gS` switches to the full spec. Only the Description field
--- of the spec is replaced; every other field goes back byte-for-byte, so the file list can't
--- be edited by accident.
---
--- Pending CLs: `change -o N` / `change -i`. Submitted CLs: `change -o -u N` / `change -u -i`
--- (owner update), with an opt-in `-f` retry (`change.allow_force`) after confirmation. The
--- default changelist has no description (callers don't offer editing it).

local p4 = require('perforated.p4')
local cls = require('perforated.changelists')
local config = require('perforated.config')

local M = {}

local function notify(msg, level)
  require('perforated.ui.toast').notify('[perforated] ' .. msg, level or vim.log.levels.INFO)
end

--- Open the description float, or turn an existing float into it (`opts.win`: the `K` popup's
--- edit mode keeps its place and size).
---@param opts { title: string, lines: string[], insert: boolean?, win: integer?, on_save: fun(desc: string, close: fun()), on_cancel: fun(how: 'cancel'|'leave')?, on_full: fun()? }
---@return integer buf, integer win
local function open_float(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, ('perforated://description/%d'):format(buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'perforated-description'
  vim.bo[buf].textwidth = 0

  local frame = {
    title = ' ' .. opts.title .. ' ',
    title_pos = 'left',
    footer = ' :w / <C-s> save · q cancel' .. (opts.on_full and ' · gS full spec ' or ' '),
    footer_pos = 'right',
  }
  local win = opts.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_config(win, frame)
    vim.wo[win][0].cursorline = false
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  else
    local width = math.min(math.max(72, vim.fn.strdisplaywidth(opts.title) + 6), vim.o.columns - 6)
    local height = math.min(math.max(#opts.lines + 2, 8), math.floor(vim.o.lines * 0.6))
    win = vim.api.nvim_open_win(
      buf,
      true,
      vim.tbl_extend('force', frame, {
        relative = 'editor',
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
      })
    )
  end
  vim.wo[win][0].wrap = true
  vim.wo[win][0].winhighlight = 'NormalFloat:PerforatedFloat,FloatBorder:PerforatedFloatBorder'
  -- Soft ruler where Swarm/P4V truncate the summary line.
  vim.wo[win][0].colorcolumn = '73'

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function save()
    local desc = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    desc = vim.trim(desc)
    if desc == '' then
      return notify('description is empty', vim.log.levels.WARN)
    end
    opts.on_save(desc, function()
      vim.bo[buf].modified = false
      close()
    end)
  end
  local function cancel()
    if vim.bo[buf].modified then
      local c = require('perforated.ui.prompt').confirm(
        'Discard the edited description?',
        '&Discard\n&Keep editing',
        2
      )
      if c ~= 1 then
        return
      end
    end
    vim.bo[buf].modified = false
    close()
    if opts.on_cancel then
      opts.on_cancel('cancel')
    end
  end
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = save })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    vim.cmd('stopinsert')
    save()
  end, { buffer = buf })
  vim.keymap.set('n', 'q', cancel, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, nowait = true })
  if opts.on_full then
    vim.keymap.set('n', 'gS', function()
      vim.bo[buf].modified = false
      close()
      opts.on_full()
    end, { buffer = buf, nowait = true })
  end
  -- Leaving the float without saving (e.g. <C-w>w) closes it like a cancel.
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if
          not closed
          and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_get_current_win() ~= win
        then
          close()
          if opts.on_cancel then
            opts.on_cancel('leave')
          end
        end
      end)
    end,
  })
  -- Highlight the summary line.
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('perforated.desc'), 0, 0, {
    line_hl_group = 'PerforatedTitle',
  })
  if opts.insert then
    vim.cmd('startinsert!')
  end
  return buf, win
end

---@param ws perforated.Workspace
---@param change string
local function remember(ws, change, desc)
  ws.clmemo[change] = vim.tbl_extend('force', ws.clmemo[change] or {}, { desc = desc })
  if ws.sticky_cl == change then
    ws.sticky_desc = desc
  end
  require('perforated.core.events').emit('Changed', { ws = ws.key, change = change })
end

--- Full spec in an acwrite buffer (jobs, type, files …); `:w` runs `change -i`.
---@param ws perforated.Workspace
---@param change string
---@param opts { submitted: boolean?, on_done: fun(ok: boolean)? }?
function M.full(ws, change, opts)
  opts = opts or {}
  cls.change_spec(ws, change, { submitted = opts.submitted }, function(spec, err)
    if not spec then
      return notify('could not load CL ' .. change .. ': ' .. tostring(err), vim.log.levels.ERROR)
    end
    vim.cmd('botright new')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, 'perforated://change/' .. change)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(spec, '\n', { plain = true }))
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = 'perforated-spec'
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      callback = function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        cls.save_spec(ws, text, { submitted = opts.submitted }, function(ok, msg)
          if ok then
            vim.bo[buf].modified = false
            notify(msg)
            remember(ws, change, cls.spec_get_description(text))
            if opts.on_done then
              opts.on_done(true)
            end
          else
            notify('saving CL ' .. change .. ' failed: ' .. msg, vim.log.levels.ERROR)
          end
        end)
      end,
    })
    vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true })
  end)
end

--- Edit the description of a pending or submitted changelist.
---@param ws perforated.Workspace
---@param change string
--- `opts.win`: turn this float into the editor instead of opening one. `on_done(saved, how)`
--- runs once: saved = true after a save; nil when dismissed, `how` = 'cancel' (q, <Esc>) or
--- 'leave' (the cursor left the float).
---@param opts { submitted: boolean?, win: integer?, on_done: fun(ok: boolean?, how: string?)? }?
function M.edit(ws, change, opts)
  opts = opts or {}
  if change == 'default' then
    return notify(
      'the default changelist has no description: move its files to a new changelist (gm)',
      vim.log.levels.WARN
    )
  end
  cls.change_spec(ws, change, { submitted = opts.submitted }, function(spec, err)
    if not spec then
      return notify('could not load CL ' .. change .. ': ' .. tostring(err), vim.log.levels.ERROR)
    end
    local status = spec:match('\nStatus:%s*(%S+)') or (opts.submitted and 'submitted' or 'pending')
    local user = spec:match('\nUser:%s*(%S+)') or '?'
    local desc = cls.spec_get_description(spec)
    -- on_done fires once: true after a save, nil when the float is dismissed.
    local finished = false
    local function done(saved, how)
      if not finished and opts.on_done then
        finished = true
        opts.on_done(saved, how)
      end
    end
    open_float({
      title = ('CL %s · %s · %s'):format(change, status, user),
      lines = vim.split(desc, '\n', { plain = true }),
      win = opts.win,
      on_cancel = function(how)
        done(nil, how)
      end,
      on_full = function()
        M.full(ws, change, opts)
      end,
      on_save = function(new_desc, close)
        local text = cls.spec_set_description(spec, new_desc)
        local submitted = status == 'submitted'
        cls.save_spec(ws, text, { submitted = submitted }, function(ok, msg)
          if ok then
            close()
            notify(('CL %s description saved'):format(change))
            remember(ws, change, new_desc)
            done(true)
            return
          end
          if submitted and config.get().change.allow_force then
            local c = require('perforated.ui.prompt').confirm(
              ('Saving failed:\n%s\n\nRetry with -f (admin force)?'):format(msg),
              '&Force\n&Cancel',
              2
            )
            if c == 1 then
              return cls.save_spec(ws, text, { force = true }, function(ok2, msg2)
                if ok2 then
                  close()
                  notify(('CL %s description saved (forced)'):format(change))
                  remember(ws, change, new_desc)
                  done(true)
                else
                  notify('forced save failed: ' .. msg2, vim.log.levels.ERROR)
                end
              end)
            end
          end
          notify(('saving CL %s failed: %s'):format(change, msg), vim.log.levels.ERROR)
        end)
      end,
    })
  end)
end

--- Create a new (empty) pending changelist from a description entered in the float.
---@param ws perforated.Workspace
---@param opts { on_done: fun(change: string?, desc: string?)? }?
function M.new(ws, opts)
  opts = opts or {}
  local template = config.get().change.template
  if type(template) == 'function' then
    template = template(ws)
  end
  -- on_done runs once: a save in flight when the float is closed still decides the outcome.
  local done, saving, cancelled = false, false, false
  local function finish(cl, desc)
    if not done then
      done = true
      if opts.on_done then
        opts.on_done(cl, desc)
      end
    end
  end
  open_float({
    title = 'New changelist',
    lines = template and vim.split(template, '\n', { plain = true }) or { '' },
    insert = true,
    on_save = function(desc, close)
      saving = true
      p4.new_change(ws, desc, function(cl, err)
        saving = false
        if not cl then
          notify('could not create changelist: ' .. tostring(err), vim.log.levels.ERROR)
          if cancelled then
            finish(nil)
          end
          return
        end
        close()
        notify('created CL ' .. cl)
        remember(ws, cl, desc)
        finish(cl, desc)
      end)
    end,
    on_cancel = function()
      cancelled = true
      if not saving then
        finish(nil)
      end
    end,
  })
end

return M
