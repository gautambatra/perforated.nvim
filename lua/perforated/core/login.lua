--- Logging in (loaded with the first login): the password prompt and `p4 login`, and getting
--- back online from `offline_auth` once a ticket exists.
---
--- `p4 login` gets no timeout: with browser-based multi-factor authentication it waits until the
--- sign-in finishes in the browser. While it waits, a busy pop-up offers Ctrl+c (a cancelled
--- login). While `offline_auth`, each return to Neovim (FocusGained, throttled by
--- `poll.focus_throttle`) checks the ticket (`p4 login -s`, no prompt): a login finished in the
--- browser, a terminal or P4V brings the workspace back online.

local M = {}

--- How long `p4 login` runs before the busy pop-up shows (a quick password login shows none).
M.BUSY_MS = 500

---@param conn perforated.Conn
---@param cb fun(ok: boolean)
function M.login(conn, cb)
  local user = conn.ws.settings and conn.ws.settings.P4USER or ''
  local prompt = ('Perforce password%s: '):format(user ~= '' and (' for ' .. user) or '')
  local ok_input, pw = pcall(vim.fn.inputsecret, prompt)
  if not ok_input or pw == nil or pw == '' then
    conn:_set('offline_auth', 'login cancelled')
    return cb(false)
  end
  local toast = require('perforated.ui.toast')
  local ctl, stopped, close, finished
  local timer = vim.defer_fn(function()
    if finished then
      return
    end
    close = toast.busy('Waiting for the sign-in to finish…', {
      cancel = function()
        stopped = true
        if ctl then
          ctl.cancel()
        end
      end,
    })
  end, M.BUSY_MS)
  conn.ws:run({ 'login' }, {
    probe = true,
    force = true,
    stdin = pw,
    priority = 1,
    no_auth_retry = true,
    timeout = 0,
    on_spawn = function(c)
      ctl = c
      if stopped then
        c.cancel()
      end
    end,
  }, function(res)
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if close then
      close()
    end
    if res.ok then
      conn.epoch = conn.epoch + 1
      conn:_set('online')
      return cb(true)
    end
    if res.cancelled or stopped then
      conn:_set('offline_auth', 'login cancelled')
      return cb(false)
    end
    -- p4's own words: an error, else what it printed (an SSO or MFA step may fail with only a
    -- message of lower severity).
    -- (the runner's `exit N` says nothing)
    local first = res.errors[1]
    local msg = (first and not first:match('^exit %d+$') and first)
      or (vim.trim(res.stderr or '') ~= '' and vim.trim(res.stderr))
      or res.warnings[1]
      or res.err
      or 'p4 login failed'
    conn:_set('offline_auth', msg)
    toast.notify('[perforated] login failed: ' .. msg, vim.log.levels.ERROR)
    cb(false)
  end)
end

local watched = {} ---@type table<perforated.Conn, true>
local group ---@type integer?
local last_check = 0

--- While logged out, check the ticket on returning to Neovim.
---@param conn perforated.Conn
function M.watch(conn)
  watched[conn] = true
  if group then
    return
  end
  group = vim.api.nvim_create_augroup('perforated.login', { clear = true })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      local now = vim.uv.now()
      if now - last_check < require('perforated.config').get().poll.focus_throttle * 1000 then
        return
      end
      last_check = now
      for c in pairs(watched) do
        M.check(c)
      end
    end,
  })
end

--- Is there a valid ticket now (`p4 login -s`)? Then the workspace is back online.
---@param conn perforated.Conn
function M.check(conn)
  if conn.state ~= 'offline_auth' or conn.login_pending or conn.checking_ticket then
    watched[conn] = conn.state == 'offline_auth' or nil
    return
  end
  conn.checking_ticket = true
  conn.ws:run(
    { 'login', '-s' },
    { probe = true, priority = 3, no_auth_retry = true, no_observe = true },
    function(res)
      conn.checking_ticket = nil
      if res.ok and conn.state == 'offline_auth' then
        require('perforated.core.debug').log('info', 'conn', '%s: a valid ticket', conn.ws.key)
        conn.epoch = conn.epoch + 1
        watched[conn] = nil
        conn:_set('online')
      end
    end
  )
end

return M
