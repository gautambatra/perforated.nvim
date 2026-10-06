--- The look of diff windows (`diff.colors`, `diff.syntax`), per window: each diff window gets
--- a highlight namespace (`nvim_win_set_hl_ns`). Groups the namespace defines override the
--- colorscheme in that window only; everything else falls back to the global colours. Nothing
--- global changes, so other tabs keep their theme and switching tabs costs nothing.
---
--- Two namespaces:
---   code — the diff sides. With `syntax = false` every highlight group except a set of UI
---          groups (line numbers, cursor line, selection, search, diff colours, diagnostics…)
---          is blanked (`{}` = no colour: plain text, the diff background still shows). The
---          buffers keep treesitter / LSP running, so the same file elsewhere stays coloured.
---   ui   — the file panel. Only with `colors = 'perforated'`.
--- With `colors = 'perforated'` both also get the plugin's palette (onedark's light style).
---
--- Both are rebuilt when the colorscheme changes and when a diff opens (to catch groups
--- plugins created since); new settings get new namespaces.

local M = {}

-- Namespaces for the current settings. A namespace's groups can't be removed (`{}` means "no
-- colour", not "use the global one"), so a change of settings starts new namespaces; for the
-- same settings, a rebuild only adds or overwrites groups.
M.ns_code, M.ns_ui = nil, nil

--- The plugin's palette: onedark's light style. `diff.colors = { … }` overrides entries.
M.PALETTE = {
  bg = '#fafafa',
  bg1 = '#f0f0f0', -- cursor line, winbar, folds
  bg2 = '#e6e6e6', -- LSP references
  bg3 = '#dcdcdc', -- selection
  fg = '#383a42',
  grey = '#a0a1a7', -- line numbers, comments
  light_grey = '#818387',
  red = '#e45649',
  green = '#50a14f',
  orange = '#c18401',
  yellow = '#986801',
  blue = '#4078f2',
  purple = '#a626a4',
  cyan = '#0184bc',
  search = '#e2c792',
  diff_add = '#e2fbe4',
  diff_delete = '#fce2e5',
  diff_change = '#e2ecfb',
  diff_text = '#cad3e0',
  separator = '#000000', -- window separators: a crisp line
}

-- Groups that aren't syntax: kept (with `colors = 'colorscheme'` they keep the colorscheme's
-- colours; with 'perforated' the palette defines the main ones).
local KEEP = {
  'Normal',
  'Cursor',
  'LineNr',
  'Sign',
  'Fold',
  'Diff',
  'Diagnostic',
  'LspReference',
  'LspInlayHint',
  'LspCodeLens',
  'LspSignature',
  'Spell',
  'Search',
  'IncSearch',
  'CurSearch',
  'Substitute',
  'MatchParen',
  'Visual',
  'WinBar',
  'WinSeparator',
  'VertSplit',
  'StatusLine',
  'TabLine',
  'EndOfBuffer',
  'NonText',
  'Whitespace',
  'SpecialKey',
  'Conceal',
  'ColorColumn',
  'QuickFixLine',
  'Pmenu',
  'Float',
  'Msg',
  'ErrorMsg',
  'WarningMsg',
  'ModeMsg',
  'MoreMsg',
  'Question',
  'Title',
  'Directory',
  'TermCursor',
  'WildMenu',
  'Added',
  'Changed',
  'Removed',
  'Perforated',
  'GitSigns',
  'MiniDiff',
  'MiniIcons',
  'DevIcon',
}

---@param name string
---@return boolean
local function kept(name)
  for _, p in ipairs(KEEP) do
    if name:sub(1, #p) == p then
      return true
    end
  end
  return false
end
M._kept = kept

--- UI groups in the plugin's palette.
---@param c table palette
local function ui_groups(c)
  local und = function(col)
    return { undercurl = true, sp = col }
  end
  return {
    Normal = { fg = c.fg, bg = c.bg },
    NormalNC = { fg = c.fg, bg = c.bg },
    EndOfBuffer = { fg = c.bg },
    LineNr = { fg = c.grey },
    LineNrAbove = { fg = c.grey },
    LineNrBelow = { fg = c.grey },
    CursorLineNr = { fg = c.fg, bold = true },
    CursorLine = { bg = c.bg1 },
    CursorColumn = { bg = c.bg1 },
    ColorColumn = { bg = c.bg1 },
    SignColumn = { bg = c.bg },
    FoldColumn = { fg = c.grey, bg = c.bg },
    Folded = { fg = c.light_grey, bg = c.bg1 },
    Visual = { bg = c.bg3 },
    VisualNOS = { bg = c.bg3 },
    Search = { fg = c.fg, bg = c.search },
    IncSearch = { fg = c.bg, bg = c.orange },
    CurSearch = { fg = c.bg, bg = c.orange },
    Substitute = { fg = c.bg, bg = c.green },
    MatchParen = { bg = c.bg3, bold = true },
    NonText = { fg = c.grey },
    Whitespace = { fg = c.bg3 },
    SpecialKey = { fg = c.grey },
    Conceal = { fg = c.grey },
    WinBar = { fg = c.fg, bg = c.bg1, bold = true },
    WinBarNC = { fg = c.light_grey, bg = c.bg1 },
    -- A separator cell doesn't take the window's Normal background: give it the palette's,
    -- or it shows the colorscheme's (a dark stripe between light windows).
    WinSeparator = { fg = c.separator, bg = c.bg },
    VertSplit = { fg = c.separator, bg = c.bg },
    Title = { fg = c.blue, bold = true },
    Directory = { fg = c.blue },
    QuickFixLine = { bg = c.bg2 },
    DiffAdd = { bg = c.diff_add },
    DiffChange = { bg = c.diff_change },
    DiffDelete = { fg = c.bg3, bg = c.diff_delete },
    DiffText = { bg = c.diff_text },
    Added = { fg = c.green },
    Changed = { fg = c.blue },
    Removed = { fg = c.red },
    ErrorMsg = { fg = c.red },
    WarningMsg = { fg = c.yellow },
    DiagnosticError = { fg = c.red },
    DiagnosticWarn = { fg = c.yellow },
    DiagnosticInfo = { fg = c.cyan },
    DiagnosticHint = { fg = c.purple },
    DiagnosticOk = { fg = c.green },
    DiagnosticVirtualTextError = { fg = c.red },
    DiagnosticVirtualTextWarn = { fg = c.yellow },
    DiagnosticVirtualTextInfo = { fg = c.cyan },
    DiagnosticVirtualTextHint = { fg = c.purple },
    DiagnosticUnderlineError = und(c.red),
    DiagnosticUnderlineWarn = und(c.yellow),
    DiagnosticUnderlineInfo = und(c.cyan),
    DiagnosticUnderlineHint = und(c.purple),
    SpellBad = und(c.red),
    SpellCap = und(c.yellow),
    SpellRare = und(c.purple),
    SpellLocal = und(c.cyan),
    LspReferenceText = { bg = c.bg2 },
    LspReferenceRead = { bg = c.bg2 },
    LspReferenceWrite = { bg = c.bg2 },
    LspInlayHint = { fg = c.grey },
    PerforatedBlame = { fg = c.grey, italic = true },
  }
end

--- Classic syntax groups in the plugin's palette (the file panel; the diff sides with
--- `syntax = true`).
---@param c table palette
local function syntax_groups(c)
  return {
    Comment = { fg = c.grey, italic = true },
    Constant = { fg = c.cyan },
    String = { fg = c.green },
    Character = { fg = c.orange },
    Number = { fg = c.orange },
    Boolean = { fg = c.orange },
    Float = { fg = c.orange },
    Identifier = { fg = c.red },
    Function = { fg = c.blue },
    Statement = { fg = c.purple },
    Conditional = { fg = c.purple },
    Repeat = { fg = c.purple },
    Label = { fg = c.purple },
    Operator = { fg = c.purple },
    Keyword = { fg = c.purple },
    Exception = { fg = c.purple },
    PreProc = { fg = c.purple },
    Include = { fg = c.purple },
    Define = { fg = c.purple },
    Macro = { fg = c.red },
    PreCondit = { fg = c.purple },
    Type = { fg = c.yellow },
    StorageClass = { fg = c.yellow },
    Structure = { fg = c.yellow },
    Typedef = { fg = c.yellow },
    Special = { fg = c.red },
    SpecialChar = { fg = c.red },
    Tag = { fg = c.red },
    Delimiter = { fg = c.light_grey },
    SpecialComment = { fg = c.grey },
    Underlined = { underline = true },
    Todo = { fg = c.red, bold = true },
    Error = { fg = c.red },
  }
end

-- Treesitter / LSP captures → the classic group they stand for, by their first component
-- (`@keyword.return.lua` → Keyword; `@lsp.type.class.cpp` → Type). Anything else is plain.
local CAPTURE = {
  comment = 'Comment',
  string = 'String',
  character = 'Character',
  number = 'Number',
  float = 'Float',
  boolean = 'Boolean',
  constant = 'Constant',
  enumMember = 'Constant',
  ['function'] = 'Function',
  method = 'Function',
  constructor = 'Function',
  decorator = 'Function',
  keyword = 'Keyword',
  conditional = 'Conditional',
  ['repeat'] = 'Repeat',
  exception = 'Exception',
  label = 'Label',
  operator = 'Operator',
  include = 'Include',
  module = 'Include',
  namespace = 'Include',
  define = 'Define',
  macro = 'Macro',
  preproc = 'PreProc',
  attribute = 'PreProc',
  type = 'Type',
  class = 'Type',
  enum = 'Type',
  interface = 'Type',
  struct = 'Type',
  typeParameter = 'Type',
  storageclass = 'StorageClass',
  structure = 'Structure',
  property = 'Identifier',
  field = 'Identifier',
  tag = 'Tag',
  punctuation = 'Delimiter',
  regexp = 'String',
}

---@param name string  e.g. '@keyword.return.lua', '@lsp.type.class.cpp'
---@return string?  the classic group it maps to (nil: plain)
local function capture_group(name)
  if name:sub(1, 6) == '@diff.' then
    local kind = name:match('^@diff%.(%a+)')
    return ({ plus = 'Added', minus = 'Removed', delta = 'Changed' })[kind]
  end
  local root = name:match('^@lsp%.%a+%.([%w_]+)') or name:match('^@([%w_]+)')
  return root and CAPTURE[root]
end
M._capture_group = capture_group

--- The effective config: colours (nil = the colorscheme's, else a palette) and syntax.
---@return table? palette, boolean syntax
function M.settings()
  local cfg = require('perforated.config').get().diff or {}
  local colors = cfg.colors
  local palette
  if colors == 'perforated' then
    palette = M.PALETTE
  elseif type(colors) == 'table' then
    palette = vim.tbl_extend('force', M.PALETTE, colors)
  end
  return palette, cfg.syntax == true
end

local built -- settings the namespaces were built for, nil = not built

--- (Re)build both namespaces from the current colorscheme and config.
function M.build()
  local palette, syntax = M.settings()
  local key = vim.inspect({ palette, syntax })
  if key ~= built then
    M.ns_code = vim.api.nvim_create_namespace('perforated.diff.look.code.' .. key)
    M.ns_ui = vim.api.nvim_create_namespace('perforated.diff.look.ui.' .. key)
  end
  local ui = palette and ui_groups(palette) or {}
  local syn = palette and syntax_groups(palette) or {}
  local set = vim.api.nvim_set_hl
  local all = vim.api.nvim_get_hl(0, {})
  for name in pairs(all) do
    if palette then
      -- ui: the panel. Classic groups from the palette, captures mapped onto them.
      local target = name:sub(1, 1) == '@' and capture_group(name)
      if ui[name] or syn[name] then
        set(M.ns_ui, name, ui[name] or syn[name])
      elseif target then
        set(M.ns_ui, name, { link = target })
      elseif name:sub(1, 1) == '@' then
        set(M.ns_ui, name, {})
      end
    end
    -- code: the diff sides.
    if not syntax and not kept(name) then
      set(M.ns_code, name, {}) -- no colour: plain text
    elseif palette and (ui[name] or syn[name]) then
      set(M.ns_code, name, ui[name] or syn[name])
    elseif palette and syntax and name:sub(1, 1) == '@' then
      local target = capture_group(name)
      set(M.ns_code, name, target and { link = target } or {})
    end
  end
  -- Palette groups the colorscheme doesn't define (yet).
  for name, spec in pairs(ui) do
    set(M.ns_ui, name, spec)
    set(M.ns_code, name, spec)
  end
  for name, spec in pairs(syn) do
    set(M.ns_ui, name, spec)
    if syntax then
      set(M.ns_code, name, spec)
    end
  end
  if not palette and not syntax then
    -- Plain text keeps the colorscheme's own text colour; blame stays dimmed.
    set(M.ns_code, 'PerforatedBlame', vim.api.nvim_get_hl(0, { name = 'Comment', link = false }))
  end
  built = key
  if not M._autocmd then
    M._autocmd = vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('perforated.diff.look', { clear = true }),
      callback = function()
        if built then
          M.build()
        end
      end,
    })
  end
end

--- The namespace for a kind of diff window, or nil when the look leaves it alone.
---@param kind 'code'|'ui'
---@return integer?
function M.ns(kind)
  local palette, syntax = M.settings()
  if kind == 'ui' then
    return palette and M.ns_ui or nil
  end
  return (palette or not syntax) and M.ns_code or nil
end

--- Whether the look changes anything at all (else diff windows are left alone).
---@return boolean
function M.active()
  local palette, syntax = M.settings()
  return palette ~= nil or not syntax
end

--- Rebuild for a new diff (groups plugins created since the last build), then give each
--- window its namespace. `opts.rebuild = false` only (re)assigns the namespaces: after a diff
--- tab switches files, since `:diffoff` / `:diffthis` fire OptionSet, and a user's hook there
--- may have reset the window's namespace.
---@param wins table<integer, 'code'|'ui'>  window → kind
---@param opts { rebuild: boolean? }?
function M.apply(wins, opts)
  if not M.active() then
    return -- the colorscheme, with syntax: nothing to do
  end
  if built == nil or not (opts and opts.rebuild == false) then
    M.build()
  end
  for win, kind in pairs(wins) do
    local ns = M.ns(kind)
    if ns and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_hl_ns(win, ns)
    end
  end
end

return M
