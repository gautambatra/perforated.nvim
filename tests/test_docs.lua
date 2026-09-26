-- doc/perforated.txt is generated from the code (scripts/gen_doc.lua): it must be up to date.
local H = require('tests.helpers')
local T = MiniTest.new_set()

T['doc/perforated.txt is up to date (run `make doc`)'] = function()
  local out = H.tmp() .. '/perforated.txt'
  local res = vim
    .system({
      vim.v.progpath,
      '--headless',
      '--noplugin',
      '-u',
      H.root .. '/tests/minimal_init.lua',
      '-l',
      H.root .. '/scripts/gen_doc.lua',
      out,
    }, { cwd = H.root, text = true })
    :wait(60000)
  H.eq(res.code, 0)
  local want = vim.fn.readfile(out)
  local have = vim.fn.readfile(H.root .. '/doc/perforated.txt')
  if not vim.deep_equal(want, have) then
    for i = 1, math.max(#want, #have) do
      if want[i] ~= have[i] then
        error(
          ('doc/perforated.txt is stale (run `make doc`); first difference at line %d:\n  generated: %s\n  committed: %s'):format(
            i,
            tostring(want[i]),
            tostring(have[i])
          )
        )
      end
    end
  end
end

return T
