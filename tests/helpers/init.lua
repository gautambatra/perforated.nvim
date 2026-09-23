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
  local dir = ('%s/tests/.tmp/%d-%d-%d'):format(
    H.root,
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
  H.write(path, 'return ' .. vim.inspect(rules))
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
  local config = opts.config or { p4 = H.fake_p4 }
  child.lua('vim.g.perforated = ...', { config })
  return child
end

--- Wait in the child until a Lua expression is truthy.
---@return boolean
function H.wait(child, expr, timeout)
  return child.lua(
    ('return vim.wait(%d, function() return (%s) and true or false end, 10)'):format(
      timeout or 5000,
      expr
    )
  )
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
