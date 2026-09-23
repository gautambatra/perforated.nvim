--- Highlight groups (all `default` links, so colorschemes and users can override).

local M = {}

local LINKS = {
  PerforatedAdd = 'Added',
  PerforatedChange = 'Changed',
  PerforatedDelete = 'Removed',
  PerforatedStale = 'DiagnosticWarn',
  PerforatedUnresolved = 'DiagnosticError',
  PerforatedOffline = 'DiagnosticError',
  PerforatedTitle = 'Title',
  PerforatedKey = 'Special',
  PerforatedDim = 'Comment',
  PerforatedChangelist = 'Identifier',
  PerforatedFloat = 'NormalFloat',
  PerforatedFloatBorder = 'FloatBorder',
  PerforatedToast = 'NormalFloat',
  PerforatedToastBorder = 'DiagnosticWarn',
  PerforatedPreviewAdd = 'DiffAdd',
  PerforatedSection = 'Title',
  PerforatedHeader = 'Comment',
  PerforatedPath = 'Normal',
  PerforatedAction = 'Statement',
  PerforatedRev = 'Comment',
  PerforatedBadge = 'WarningMsg',
  PerforatedShelved = 'Constant',
  PerforatedShelvedFile = 'Special',
  PerforatedDiffAdded = 'Added',
  PerforatedDiffRemoved = 'Removed',
  PerforatedDiffHunk = 'Title',
  PerforatedAnnotateLocal = 'DiagnosticInfo',
  PerforatedBlame = 'Comment',
  PerforatedMark = 'Todo',
  PerforatedFooter = 'StatusLineNC',
  PerforatedLoading = 'Comment',
  PerforatedPreviewDelete = 'DiffDelete',
}

local done = false

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  if not done then
    done = true
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('perforated.hl', { clear = true }),
      callback = M.setup,
    })
  end
end

return M
