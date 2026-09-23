local H = require('tests.helpers')
local T = MiniTest.new_set()

local child, root

local CONNECT_FAIL = {
  stderr = 'Perforce client error:\n\tConnect to server failed; check $P4PORT.\n\tTCP connect to x:1666 failed.\n',
  code = 1,
}

local function setup(rules)
  root = H.tmp()
  H.write(root .. '/.p4config', 'P4CLIENT=ws1\n')
  H.write(root .. '/a.c', 'x')
  child = H.child({ fake = { rules = rules }, env = { P4CONFIG = '.p4config' } })
  child.lua(([[
    _G.ws = require('perforated.core.activation').for_dir(%q)
    _G.run = function(args)
      _G.res = nil
      _G.ws:run(args, {}, function(r) _G.res = r end)
    end
  ]]):format(root))
end

local function run(args)
  child.lua('_G.run(...)', { args })
  H.eq(H.wait(child, '_G.res ~= nil', 10000), true)
  return child.lua_get('_G.res')
end

T['offline'] = MiniTest.new_set({ hooks = {
  post_case = function()
    child.stop()
  end,
} })

T['offline']['connection failure → offline, fail fast, probe recovers'] = function()
  setup({ vim.tbl_extend('force', { match = '.' }, CONNECT_FAIL) })
  local r = run({ 'opened' })
  H.eq(r.ok, false)
  H.eq(child.lua_get('_G.ws.conn.state'), 'offline')
  H.eq(child.lua_get('_G.ws.conn.timer ~= nil'), true)

  -- Further calls are refused without spawning p4.
  local before = #H.calls(child.fake.log)
  r = run({ 'fstat', 'x' })
  H.eq(r.refused, true)
  H.eq(#H.calls(child.fake.log), before)

  -- Server comes back; a probe flips us online and later calls go through.
  H.rules(child.fake.rules, { { match = '.', records = { { serverVersion = 'x' } } } })
  child.lua('_G.probed = nil; _G.ws.conn:probe(function(ok) _G.probed = ok end)')
  H.eq(H.wait(child, '_G.probed ~= nil'), true)
  H.eq(child.lua_get('_G.probed'), true)
  H.eq(child.lua_get('_G.ws.conn.state'), 'online')
  r = run({ 'fstat', 'x' })
  H.eq(r.ok, true)
end

T['offline']['server-side errors do not mark the connection offline'] = function()
  setup({ { match = '.', records = { { data = 'no such file(s).', generic = 17, severity = 3 } } } })
  local r = run({ 'fstat', 'x' })
  H.eq(r.ok, false)
  H.eq(child.lua_get('_G.ws.conn.state'), 'online')
end

T['auth'] = MiniTest.new_set({ hooks = {
  post_case = function()
    child.stop()
  end,
} })

local AUTH_ERR =
  { { data = 'Your session has expired, please login again.\n', generic = 36, severity = 3 } }

T['auth']['expired ticket → one prompt → login via stdin → original call retried'] = function()
  local marker = H.tmp() .. '/logged-in'
  setup({
    { match = '^login', touch = marker, records = { { User = 'alice' } } },
    { match = '^opened', unless = marker, records = AUTH_ERR },
    { match = '^opened', records = { { depotFile = '//depot/a.c' } } },
  })
  child.lua([[
    _G.prompts = 0
    vim.fn.inputsecret = function() _G.prompts = _G.prompts + 1; return 's3cret' end
  ]])
  -- Two concurrent calls hit the auth error; only one prompt must appear.
  child.lua([[
    _G.r1, _G.r2 = nil, nil
    _G.ws:run({ 'opened' }, {}, function(r) _G.r1 = r end)
    _G.ws:run({ 'opened', '-a' }, {}, function(r) _G.r2 = r end)
  ]])
  H.eq(H.wait(child, '_G.r1 ~= nil and _G.r2 ~= nil', 10000), true)
  H.eq(child.lua_get('_G.prompts'), 1)
  H.eq(child.lua_get('_G.r1.ok'), true)
  H.eq(child.lua_get('_G.r2.ok'), true)
  H.eq(child.lua_get('_G.ws.conn.state'), 'online')
  local login = H.calls_matching(child.fake.log, 'login')
  H.eq(#login, 1)
  H.eq(login[1].stdin, 's3cret')
  H.eq(child.lua_get([[require('perforated.core.queue').global().paused[_G.ws.key] ]]), vim.NIL)
end

T['auth']['cancelled prompt → offline_auth, calls fail fast with a hint'] = function()
  setup({ { match = '^opened', records = AUTH_ERR } })
  child.lua([[vim.fn.inputsecret = function() return '' end]])
  local r = run({ 'opened' })
  H.eq(r.ok, false)
  H.eq(child.lua_get('_G.ws.conn.state'), 'offline_auth')
  r = run({ 'opened' })
  H.eq(r.refused, true)
  H.expect.no_equality(r.errors[1]:find(':P4 login', 1, true), nil)
end

return T
