-- lualine component: `sections = { lualine_c = { 'perforated' } }`
--
-- Shows the current file's Perforce state (e.g. `edit@123 +3 ~1 ↓#4→#5`) plus workspace
-- markers (`↓2` stale opened files, `!1` unresolved, `⊘` offline). Empty outside Perforce.
local M = require('lualine.component'):extend()

function M:update_status()
  return require('perforated').statusline()
end

return M
