-- Test entry point: `make test` or `make test FILE=tests/test_parse.lua`.
return function(file)
  local MiniTest = require('mini.test')
  MiniTest.setup()
  local root = vim.g.perforated_test_root
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
      reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
    },
  })
end
