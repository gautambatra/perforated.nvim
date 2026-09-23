--- File-type icons (mini.icons / nvim-web-devicons, optional) and status glyphs (nerd / ascii).

local M = {}

M.GLYPHS = {
  nerd = {
    edit = '',
    add = '',
    delete = '',
    move = '',
    integrate = '',
    branch = '',
    shelved = '',
    stale = '',
    unresolved = '',
    other_open = '',
    offline = '󰅛',
    changelist = '',
    default_cl = '',
    file = '',
  },
  ascii = {
    edit = 'e',
    add = 'a',
    delete = 'd',
    move = 'm',
    integrate = 'i',
    branch = 'b',
    shelved = 'S',
    stale = '!',
    unresolved = 'U',
    other_open = '⇄',
    offline = 'x',
    changelist = '#',
    default_cl = '@',
    file = ' ',
  },
}

local provider ---@type false|fun(name: string): string?, string?

local function detect()
  if provider ~= nil then
    return provider
  end
  local want = require('perforated.config').get().icons.provider
  provider = false
  if want == false then
    return provider
  end
  if want == 'auto' or want == 'mini' then
    local ok, mini = pcall(require, 'mini.icons')
    -- mini.icons only works after its setup(); probe it instead of reading its global.
    if ok and pcall(mini.get, 'file', 'x.lua') then
      provider = function(name)
        local icon, hl = mini.get('file', name)
        return icon, hl
      end
      return provider
    end
  end
  if want == 'auto' or want == 'devicons' then
    local ok, dev = pcall(require, 'nvim-web-devicons')
    if ok then
      provider = function(name)
        local ext = name:match('%.([^./]+)$')
        return dev.get_icon(name, ext, { default = true })
      end
    end
  end
  return provider
end

--- 'nerd' or 'ascii' (auto = nerd when an icon provider is installed).
---@return 'nerd'|'ascii'
function M.style()
  local s = require('perforated.config').get().icons.style
  if s == 'nerd' or s == 'ascii' then
    return s
  end
  return detect() and 'nerd' or 'ascii'
end

--- Status glyph by name (user overrides via config.icons.glyphs).
---@param name string
---@return string
function M.glyph(name)
  local custom = vim.tbl_get(require('perforated.config').get(), 'icons', 'glyphs', name)
  return custom or M.GLYPHS[M.style()][name] or ''
end

local cache = {} ---@type table<string, {[1]: string, [2]: string?}>

--- File-type icon and highlight for a file name (cached by extension/basename).
---@param path string
---@return string icon, string? hl
function M.file(path)
  local name = path:match('[^/]+$') or path
  local ext = name:match('%.([^.]+)$')
  local ckey = ext and ('.' .. ext) or name
  local hit = cache[ckey]
  if hit then
    return hit[1], hit[2]
  end
  local p = detect()
  local icon, hl = '', nil
  if p then
    icon, hl = p(name)
  end
  cache[ckey] = { icon or '', hl }
  return icon or '', hl
end

--- Glyph for a p4 file action.
---@param action string?
---@return string
function M.action(action)
  if not action then
    return ''
  end
  local base = action:match('^(%a+)')
  local map = {
    edit = 'edit',
    add = 'add',
    delete = 'delete',
    move = 'move',
    integrate = 'integrate',
    branch = 'branch',
    import = 'add',
    purge = 'delete',
    archive = 'delete',
  }
  return M.glyph(map[base] or 'file')
end

function M._reset()
  provider, cache = nil, {}
end

return M
