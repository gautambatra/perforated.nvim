-- Shared test helpers.
local MiniTest = require('mini.test')

local H = {}

H.root = vim.g.perforated_test_root
H.fake_p4 = H.root .. '/tests/bin/p4'
H.expect = MiniTest.expect
H.eq = MiniTest.expect.equality
H.neq = MiniTest.expect.no_equality

local counter = 0

--- Fresh temporary directory under tests/.tmp (resolved, no symlinks).
---@return string
function H.tmp()
  counter = counter + 1
  -- PERFORATED_TEST_TMP overrides the base (e.g. a mixed-case path, like macOS /Users/...).
  local dir = ('%s/%d-%d-%d'):format(
    vim.env.PERFORATED_TEST_TMP or (H.root .. '/tests/.tmp'),
    vim.uv.os_getpid(),
    counter,
    vim.uv.hrtime() % 1e6
  )
  vim.fn.mkdir(dir, 'p')
  return vim.uv.fs_realpath(dir)
end

---@param path string
---@param content string
function H.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(io.open(path, 'w'))
  fd:write(content)
  fd:close()
end

--- Write a fake-p4 rules file.
---@param path string
---@param rules table[]
function H.rules(path, rules)
  -- JSON, not vim.inspect: inspect writes shared tables as `<1>` references (invalid Lua).
  H.write(path, ('return vim.json.decode(%q)'):format(vim.json.encode(rules)))
end

--- Decode the fake-p4 call log.
---@param path string
---@return table[]
function H.calls(path)
  local out = {}
  local fd = io.open(path, 'r')
  if not fd then
    return out
  end
  for line in fd:lines() do
    out[#out + 1] = vim.json.decode(line)
  end
  fd:close()
  return out
end

--- Calls whose command starts with `prefix`.
function H.calls_matching(path, prefix)
  return vim.tbl_filter(function(c)
    return vim.startswith(c.cmd, prefix)
  end, H.calls(path))
end

--- Start a child Neovim with a scrubbed Perforce environment.
---
--- opts.env      extra environment variables for the child (string values; false = unset)
--- opts.config   vim.g.perforated table (default: { p4 = fake p4 })
--- opts.fake     { rules = {...} } → sets FAKE_P4_RULES/FAKE_P4_LOG; returns paths in child.fake
---@return table child
function H.child(opts)
  opts = opts or {}
  local child = MiniTest.new_child_neovim()
  local home = H.tmp()
  child.home = home
  local env = {
    HOME = home,
    P4ENVIRO = home .. '/.p4enviro',
    P4TICKETS = home .. '/.p4tickets',
    P4TRUST = home .. '/.p4trust',
    NVIM_APPNAME = 'perforated-test',
  }
  if opts.fake then
    child.fake = { rules = home .. '/rules.lua', log = home .. '/calls.jsonl' }
    H.rules(child.fake.rules, opts.fake.rules or {})
    env.FAKE_P4_RULES = child.fake.rules
    env.FAKE_P4_LOG = child.fake.log
  end
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  -- Scrub every P4* variable inherited from the developer's shell, then apply ours. This must
  -- happen before the child starts so plugin/ never sees the developer's environment.
  local saved = {}
  for k, v in pairs(vim.fn.environ()) do
    if k:match('^P4') then
      saved[k] = v
      vim.env[k] = nil
    end
  end
  local saved2 = {}
  for k, v in pairs(env) do
    saved2[k] = vim.env[k] or false
    vim.env[k] = v or nil
  end
  child.restart({ '-u', H.root .. '/tests/minimal_init.lua' })
  for k, v in pairs(saved2) do
    vim.env[k] = v or nil
  end
  for k, v in pairs(saved) do
    vim.env[k] = v
  end
  -- vim.ui.select backend by default: tests stub it (mini.pick is on the test rtp).
  local config =
    vim.tbl_deep_extend('force', { picker = 'select' }, opts.config or { p4 = H.fake_p4 })
  child.lua('vim.g.perforated = ...', { config })
  return child
end

--- Wait in the child until a Lua expression is truthy.
---@return boolean
--- Wait until the child's p4 queue has been idle (nothing running or waiting) for `quiet` ms,
--- so a test that counts p4 calls doesn't count a buffer's own late fstat or refresh. Also
--- covers the buffer layer's 30 ms fstat batching window.
---@param child table
---@param quiet integer?  default 300
function H.wait_idle(child, quiet)
  quiet = quiet or 300
  local since = vim.uv.now()
  local ok = vim.wait(15000, function()
    local busy = child.lua_get([[(function()
      local q = require('perforated.core.queue').global()
      return q.running > 0 or q:pending_count() > 0
    end)()]])
    if busy then
      since = vim.uv.now()
    end
    return vim.uv.now() - since >= quiet
  end, 50)
  H.eq(ok, true)
end

--- p4 subcommands logged in the child since `core.log.clear()`, oldest first (`fstat`,
--- `annotate`…): a count assertion that fails shows which calls were made.
---@param child table
---@return string[]
function H.p4_subcommands(child)
  return child.lua_get([=[(function()
    local with_arg = { ['-x'] = true, ['-c'] = true, ['-u'] = true, ['-p'] = true,
      ['-P'] = true, ['-H'] = true, ['-C'] = true, ['-d'] = true, ['-z'] = true }
    local out = {}
    for _, e in ipairs(require('perforated.core.log').entries()) do
      local i = 2 -- argv[1] is the p4 binary
      while e.argv[i] and e.argv[i]:sub(1, 1) == '-' do
        i = i + (with_arg[e.argv[i]] and 2 or 1)
      end
      out[#out + 1] = e.argv[i] or '?'
    end
    return out
  end)()]=])
end

--- Record busy pop-ups in the child: `_G.busy` gets `{ msg, open }` per pop-up (open = not
--- closed yet).
---@param child table
function H.record_busy(child)
  child.lua([[
    local toast = require('perforated.ui.toast')
    local busy = toast.busy
    _G.busy = {}
    toast.busy = function(msg)
      local close = busy(msg)
      local entry = { msg = msg, open = true }
      table.insert(_G.busy, entry)
      return function() entry.open = false; close() end
    end
  ]])
end

function H.wait(child, expr, timeout)
  return child.lua(
    ('return vim.wait(%d, function() return (%s) and true or false end, 10)'):format(
      timeout or 5000,
      expr
    )
  )
end

--- Everything the plugin told the user in the child: toast titles and lines (plugin messages
--- are toasts by default), plus :messages.
---@return string
function H.messages(child)
  return child.lua([[
    local out = { vim.api.nvim_exec2('messages', { output = true }).output }
    local toast = package.loaded['perforated.ui.toast']
    for _, t in ipairs(toast and toast.history() or {}) do
      out[#out + 1] = t.title .. '\n' .. table.concat(t.lines, '\n')
    end
    return table.concat(out, '\n')
  ]])
end

--- Wait until the plugin has said something containing `text`.
function H.wait_message(child, text, timeout)
  return child.lua(([[return vim.wait(%d, function()
      local toast = package.loaded['perforated.ui.toast']
      for _, t in ipairs(toast and toast.history() or {}) do
        if (t.title .. '\n' .. table.concat(t.lines, '\n')):find(%q, 1, true) then return true end
      end
      return vim.api.nvim_exec2('messages', { output = true }).output:find(%q, 1, true) ~= nil
    end, 10)]]):format(timeout or 5000, text, text))
end

--- perforated modules currently loaded in the child.
function H.loaded_modules(child)
  return child.lua([[
    local out = {}
    for name in pairs(package.loaded) do
      if name:match('^perforated') then out[#out + 1] = name end
    end
    table.sort(out)
    return out
  ]])
end

return H
