-- lualine component: `sections = { lualine_c = { 'perforated' } }`
--
-- Shows the current file's Perforce state (`statusline.format`, e.g. `alice_ws edit@123 ● #4 ↓#5`)
-- plus workspace markers (`↓2` stale opened files, `!1` unresolved, `⊘` offline, `⊘login`
-- login needed). Empty outside Perforce.
local M = require('lualine.component'):extend()

function M:update_status()
  return require('perforated').statusline()
end

return M
