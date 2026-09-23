local H = require('tests.helpers')
local T = MiniTest.new_set()

local child, root, logfile

local function rules()
  return {
    { match = '^login', records = { { User = 'alice' } } },
    {
      match = '^info',
      records = {
        {
          clientName = 'ws1',
          clientRoot = root,
          userName = 'alice',
          caseHandling = 'sensitive',
        },
      },
    },
    { match = '^set', stdout = 'P4CLIENT=ws1\n' },
    {
      match = '^fstat',
      records = {
        { depotFile = '//depot/a.c', clientFile = root .. '/a.c', haveRev = '1', headRev = '1' },
      },
    },
  }
end

local function start(env, debug_cfg)
  root = H.tmp()
  logfile = root .. '/../debug-' .. vim.uv.hrtime() .. '.log'
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(root .. '/a.c', 'x')
  child = H.child({
    fake = { rules = rules() },
    env = vim.tbl_extend('force', { P4CONFIG = '.p4config' }, env or {}),
    config = {
      p4 = H.fake_p4,
      poll = { interval = 0 },
      debug = vim.tbl_extend('force', { file = logfile }, debug_cfg or {}),
    },
  })
end

local function read_log()
  child.lua([[local d = package.loaded['perforated.core.debug']; if d then d.flush() end]])
  local fd = io.open(logfile, 'r')
  if not fd then
    return nil
  end
  local s = fd:read('*a')
  fd:close()
  return s
end

local function has(text, needle)
  H.expect.no_equality(text:find(needle, 1, true), nil)
end

T['debug'] = MiniTest.new_set({ hooks = {
  post_case = function()
    child.stop()
  end,
} })

T['debug']['off by default: nothing is written'] = function()
  start()
  child.cmd('edit ' .. root .. '/a.c')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']])
  H.eq(read_log(), nil)
end

T['debug']['PERFORATED_DEBUG=1 logs gate, activation, p4 calls and state changes'] = function()
  start({ PERFORATED_DEBUG = '1', P4PASSWD = 'hunter2' })
  child.cmd('edit ' .. root .. '/a.c')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']])
  local log = read_log()
  local pid = child.fn.getpid()
  has(log, ('[%d]'):format(pid))
  has(log, 'debug: --- debug enabled by PERFORATED_DEBUG')
  has(log, 'gate: ' .. root .. '/a.c: P4CONFIG ' .. root .. '/.p4config')
  has(log, 'workspace: created ' .. root)
  has(log, 'runner: start -Mj -ztag -x - fstat')
  has(log, 'runner: done -Mj -ztag -x - fstat')
  has(log, 'buffer: buf ')
  has(log, 'pending -> clean')
  has(log, '<redacted>') -- P4PASSWD in the environment header
  H.eq(log:find('hunter2', 1, true), nil)
end

T['debug']['login stdin is never logged'] = function()
  start({ PERFORATED_DEBUG = '1' })
  child.cmd('edit ' .. root .. '/a.c')
  child.lua([[
    vim.fn.inputsecret = function() return 's3cret-pw' end
    _G.done = nil
    require('perforated').workspace().conn:login(function(ok) _G.done = ok end)
  ]])
  H.wait(child, '_G.done ~= nil')
  local log = read_log()
  has(log, 'login cwd=')
  has(log, 'stdin=<redacted>')
  H.eq(log:find('s3cret-pw', 1, true), nil)
end

T['debug'][':P4 debug on/off/snapshot/clear at runtime; level filter'] = function()
  start()
  child.cmd('edit ' .. root .. '/a.c')
  H.wait(child, [[(require('perforated.buffer').get() or {}).status == 'clean']])
  child.cmd('P4 debug on info')
  child.cmd('P4 refresh')
  H.wait(child, [[require('perforated').workspace().info ~= nil]])
  child.cmd('P4 debug snapshot')
  local log = read_log()
  has(log, 'enabled by :P4 debug on: level=INFO')
  has(log, 'snapshot: workspace ' .. root)
  has(log, 'snapshot: buffer ')
  H.eq(log:find(' DEBUG ', 1, true), nil) -- level=info filters debug lines
  child.cmd('P4 debug off')
  local size = #read_log()
  child.cmd('P4 refresh')
  vim.uv.sleep(300)
  H.eq(#read_log(), size)
  child.cmd('P4 debug clear')
  H.eq(read_log(), nil)
end

T['debug']['rotates above max_kb'] = function()
  start({ PERFORATED_DEBUG = 'trace' }, { max_kb = 1 })
  child.lua([[
    local d = require('perforated.core.debug')
    for i = 1, 200 do d.debug('test', 'line %d %s', i, ('x'):rep(40)) end
    d.flush()
    for i = 1, 5 do d.debug('test', 'after %d', i) end
    d.flush()
  ]])
  H.expect.no_equality(vim.uv.fs_stat(logfile .. '.1'), nil)
  H.eq(vim.uv.fs_stat(logfile).size < 2048, true)
end

return T
