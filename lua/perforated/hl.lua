--- Highlight groups (all `default` links, so colorschemes and users can override).

local M = {}

local LINKS = {
  PerforatedAdd = 'Added',
  PerforatedChange = 'Changed',
  PerforatedDelete = 'Removed',
  PerforatedStale = 'DiagnosticWarn',
  PerforatedOffline = 'DiagnosticError',
  PerforatedTitle = 'Title',
  PerforatedKey = 'Special',
  PerforatedDim = 'Comment',
  PerforatedChangelist = 'Identifier',
  PerforatedFloat = 'NormalFloat',
  PerforatedFloatBorder = 'FloatBorder',
  PerforatedToast = 'NormalFloat',
  PerforatedToastBorder = 'DiagnosticWarn',
  PerforatedToastInfoBorder = 'DiagnosticInfo', -- informational toasts (e.g. "no differences")
  PerforatedToastErrorBorder = 'DiagnosticError', -- errors
  PerforatedPreviewAdd = 'DiffAdd',
  PerforatedSection = 'Title',
  PerforatedHeader = 'Comment',
  PerforatedPath = 'Normal',
  PerforatedCount = 'PerforatedModified', -- a changelist's opened-file count, when non-zero
  PerforatedAction = 'Statement',
  PerforatedRev = 'Comment',
  PerforatedBadge = 'WarningMsg',
  PerforatedShelved = 'Constant',
  PerforatedShelvedFile = 'Special',
  PerforatedDiffAdded = 'Added',
  PerforatedDiffRemoved = 'Removed',
  PerforatedDiffHunk = 'Title',
  PerforatedDiffHeader = 'WinBar', -- diff window header: the file
  PerforatedDiffHeaderKind = 'Title', -- … and which side it is: "@=12 (shelved)", "(workspace)"
  PerforatedAnnotateLocal = 'DiagnosticInfo',
  PerforatedBlame = 'Comment',
  PerforatedTimelapseAdd = 'DiffAdd', -- lines added in the shown revision
  PerforatedSliderTrack = 'Comment',
  PerforatedSliderRange = 'Visual',
  PerforatedSliderHandle = 'Special', -- ● the shown revision
  PerforatedSliderHandleA = 'Constant', -- ◆ the other end (diff / range mode)
  PerforatedTimelapseDelete = 'DiffDelete', -- lines deleted in it (virtual lines)
  PerforatedModified = 'Changed', -- opened file that differs from its base
  PerforatedMark = 'Todo',
  PerforatedFooter = 'StatusLineNC',
  PerforatedLoading = 'Comment',
  PerforatedPreviewDelete = 'DiffDelete',
}

M.LINKS = LINKS

local done = false

--- fg colour of a group as '#rrggbb' (nil without one).
local function fg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl.fg and ('#%06x'):format(hl.fg) or nil
end

--- Mix two '#rrggbb' colours (t = 0 → a, 1 → b).
function M.blend(a, b, t)
  local out = '#'
  for _, i in ipairs({ 2, 4, 6 }) do
    local x, y = tonumber(a:sub(i, i + 1), 16), tonumber(b:sub(i, i + 1), 16)
    out = out .. ('%02x'):format(math.floor(x + (y - x) * t + 0.5))
  end
  return out
end

--- Fixed colours, for meanings no standard group carries reliably.
M.COLORS = {
  -- Orange: needs action, but isn't an error (and stays apart from stale's warning colour).
  PerforatedUnresolved = { fg = '#ff8700', ctermfg = 208 },
}

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  for name, spec in pairs(M.COLORS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', spec, { default = true }))
  end
  -- Unchanged opened files: halfway between normal text and comments. Muted, but more readable
  -- than Comment (which is very faint in some themes, e.g. onedark).
  local normal, comment = fg('Normal'), fg('Comment')
  if normal and comment then
    vim.api.nvim_set_hl(
      0,
      'PerforatedUnchanged',
      { fg = M.blend(normal, comment, 0.5), default = true }
    )
  else
    vim.api.nvim_set_hl(0, 'PerforatedUnchanged', { link = 'Comment', default = true })
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
