-- Throwaway real Helix Core server for integration tests (rsh mode: no daemon, no ports).
local H = require('tests.helpers')

local P = {}

P.bin_dir = vim.env.PERFORATED_P4BIN or (H.root .. '/.deps/p4bin')
P.p4 = P.bin_dir .. '/p4'
P.p4d = P.bin_dir .. '/p4d'

---@return boolean
function P.available()
  return vim.fn.executable(P.p4) == 1 and vim.fn.executable(P.p4d) == 1
end

local Server = {}
Server.__index = Server

--- Create a fresh server.
function P.new()
  local dir = H.tmp()
  local s = setmetatable({ dir = dir, root = dir .. '/p4root' }, Server)
  vim.fn.mkdir(s.root, 'p')
  s.port = ('rsh:%s -r %s -L log -i -J off'):format(P.p4d, s.root)
  return s
end

--- Run p4 against the server synchronously (test setup only).
---@param args string[]
---@param opts { cwd: string?, stdin: string?, user: string?, client: string? }?
---@return { code: integer, stdout: string, stderr: string }
function Server:p4(args, opts)
  opts = opts or {}
  local argv = { P.p4, '-p', self.port, '-u', opts.user or 'alice' }
  if opts.client then
    vim.list_extend(argv, { '-c', opts.client })
  end
  vim.list_extend(argv, args)
  local res = vim
    .system(argv, {
      cwd = opts.cwd or self.dir,
      stdin = opts.stdin,
      text = true,
      clear_env = true,
      env = {
        PATH = vim.env.PATH,
        HOME = self.dir,
        P4ENVIRO = self.dir .. '/.p4enviro',
        P4TICKETS = self.dir .. '/.p4tickets',
        P4CONFIG = '.p4config-unused',
        PWD = opts.cwd or self.dir,
      },
    })
    :wait(20000)
  if res.code ~= 0 then
    error(
      ('p4 %s failed (%d): %s%s'):format(table.concat(args, ' '), res.code, res.stdout, res.stderr)
    )
  end
  return res
end

--- Create a client workspace rooted at `root` (default view: //depot/...).
function Server:client(name, root, user)
  vim.fn.mkdir(root, 'p')
  local spec = self:p4({ 'client', '-o', name }, { user = user }).stdout
  spec = spec:gsub('\nRoot:[^\n]*', '\nRoot:\t' .. root)
  self:p4({ 'client', '-i' }, { stdin = spec, user = user })
end

--- Write a P4CONFIG file.
function Server:p4config(dir, client, user, name)
  H.write(
    dir .. '/' .. (name or '.p4config'),
    ('P4PORT=%s\nP4USER=%s\nP4CLIENT=%s\n'):format(self.port, user or 'alice', client)
  )
end

--- Add files (rel path → content) in a client and submit them.
function Server:submit_files(client, root, files, desc, user)
  local paths = {}
  for rel, content in pairs(files) do
    local p = root .. '/' .. rel
    H.write(p, content)
    paths[#paths + 1] = p
  end
  self:p4(vim.list_extend({ 'add' }, paths), { client = client, cwd = root, user = user })
  self:p4({ 'submit', '-d', desc or 'test' }, { client = client, cwd = root, user = user })
end

return P
