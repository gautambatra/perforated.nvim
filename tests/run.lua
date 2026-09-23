-- Test entry point: `make test` or `make test FILE=tests/test_parse.lua`.
--
-- Under GitHub Actions every failed case is also emitted as an `::error` annotation, so
-- failures are readable from the run summary (and the public API) without downloading logs.
return function(file)
  local MiniTest = require('mini.test')
  MiniTest.setup()
  local root = vim.g.perforated_test_root
  local stdout = MiniTest.gen_reporter.stdout({ group_depth = 2, quit_on_finish = false })

  local function annotate_and_quit()
    local fails = 0
    for _, case in ipairs(MiniTest.current.all_cases or {}) do
      local exec = case.exec or {}
      if exec.fails and #exec.fails > 0 then
        fails = fails + 1
        if vim.env.GITHUB_ACTIONS then
          local title = table.concat(case.desc or {}, ' | '):gsub('[\r\n]', ' ')
          local msg = tostring(exec.fails[1]):gsub('\27%[[%d;]*m', '')
          msg = msg:sub(1, 3000):gsub('%%', '%%25'):gsub('\r', '%%0D'):gsub('\n', '%%0A')
          title = title:gsub('%%', '%%25'):gsub(',', '%%2C'):gsub('::', ': :')
          io.stdout:write(('::error title=%s::%s\n'):format(title, msg))
        end
      end
    end
    io.stdout:flush()
    vim.cmd(fails > 0 and 'cquit 1' or 'qall!')
  end

  MiniTest.run({
    collect = {
      find_files = function()
        if file and file ~= '' then
          return { file }
        end
        return vim.fn.globpath(root .. '/tests', 'test_*.lua', true, true)
      end,
    },
    execute = {
      reporter = {
        start = stdout.start,
        update = stdout.update,
        finish = function()
          stdout.finish()
          annotate_and_quit()
        end,
      },
    },
  })
end
