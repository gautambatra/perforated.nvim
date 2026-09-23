--- Picker abstraction: one call, any installed fuzzy finder.
---
---   require('perforated.picker').pick({
---     title = 'Pending changelists',
---     items = { … },
---     format = function(item) return 'text shown / matched' end,
---     preview = function(item) return { 'lines', … } end,   -- optional
---     multi = false,                                        -- allow multi-select
---     on_choice = function(items) … end,                    -- nil when cancelled
---   })
---
--- Backend: `picker = 'auto'` (telescope → fzf-lua → snacks → mini.pick → vim.ui.select) or
--- one of 'telescope' | 'fzf_lua' | 'snacks' | 'mini' | 'select'.

local M = {}

---@class perforated.PickSpec
---@field title string
---@field items any[]
---@field format fun(item: any): string
---@field preview (fun(item: any): string[])?
---@field multi boolean?
---@field on_choice fun(items: any[]?)

local function has(mod)
  return package.loaded[mod] ~= nil or pcall(require, mod)
end

local backends = {}

--- Call on_choice exactly once.
local function once(spec)
  local done = false
  return function(items)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      spec.on_choice(items and #items > 0 and items or nil)
    end)
  end
end

backends.select = function(spec)
  local finish = once(spec)
  vim.ui.select(spec.items, { prompt = spec.title, format_item = spec.format }, function(choice)
    finish(choice and { choice } or nil)
  end)
end

backends.telescope = function(spec)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local state = require('telescope.actions.state')
  local finish = once(spec)
  local previewer
  if spec.preview then
    previewer = require('telescope.previewers').new_buffer_previewer({
      title = spec.title,
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, spec.preview(entry.value) or {})
      end,
    })
  end
  pickers
    .new({}, {
      prompt_title = spec.title,
      finder = finders.new_table({
        results = spec.items,
        entry_maker = function(item)
          local text = spec.format(item)
          return { value = item, display = text, ordinal = text }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewer,
      attach_mappings = function(prompt_buf)
        actions.select_default:replace(function()
          local picker = state.get_current_picker(prompt_buf)
          local chosen = {}
          for _, e in ipairs(spec.multi and picker:get_multi_selection() or {}) do
            chosen[#chosen + 1] = e.value
          end
          if #chosen == 0 then
            local e = state.get_selected_entry()
            chosen = e and { e.value } or {}
          end
          finish(chosen) -- before close: its hook reports a cancel otherwise
          actions.close(prompt_buf)
        end)
        actions.close:enhance({
          post = function()
            finish(nil)
          end,
        })
        return true
      end,
    })
    :find()
end

backends.fzf_lua = function(spec)
  local finish = once(spec)
  local lines = {}
  for i, item in ipairs(spec.items) do
    lines[i] = i .. '\t' .. spec.format(item):gsub('\t', ' ')
  end
  local function values(selected)
    local out = {}
    for _, s in ipairs(selected or {}) do
      local i = tonumber(s:match('^(%d+)\t'))
      if i then
        out[#out + 1] = spec.items[i]
      end
    end
    return out
  end
  require('fzf-lua').fzf_exec(lines, {
    prompt = spec.title .. '> ',
    fzf_opts = { ['--delimiter'] = '\t', ['--with-nth'] = '2..', ['--multi'] = spec.multi or nil },
    actions = {
      ['default'] = function(selected)
        finish(values(selected))
      end,
    },
    winopts = {
      on_close = function()
        finish(nil)
      end,
    },
  })
end

backends.snacks = function(spec)
  local finish = once(spec)
  local items = {}
  for i, item in ipairs(spec.items) do
    local text = spec.format(item)
    items[i] = {
      idx = i,
      text = text,
      value = item,
      preview = spec.preview and { text = table.concat(spec.preview(item) or {}, '\n') } or nil,
    }
  end
  require('snacks').picker.pick({
    title = spec.title,
    items = items,
    format = 'text',
    preview = spec.preview and 'preview' or 'none',
    confirm = function(picker, item)
      local sel = spec.multi and picker:selected({ fallback = true }) or { item }
      picker:close()
      finish(vim.tbl_map(function(i)
        return i.value
      end, sel))
    end,
    on_close = function()
      finish(nil)
    end,
  })
end

backends.mini = function(spec)
  local finish = once(spec)
  local items = {}
  for i, item in ipairs(spec.items) do
    items[i] = { text = spec.format(item), value = item }
  end
  local MiniPick = require('mini.pick')
  local chose = false
  MiniPick.start({
    source = {
      name = spec.title,
      items = items,
      choose = function(item)
        chose = true
        finish(item and { item.value } or nil)
      end,
      choose_marked = spec.multi and function(marked)
        chose = true
        finish(vim.tbl_map(function(i)
          return i.value
        end, marked))
      end or nil,
      preview = spec.preview and function(buf, item)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, spec.preview(item.value) or {})
      end or nil,
    },
  })
  -- MiniPick.start blocks until the picker closes.
  if not chose then
    finish(nil)
  end
end

local AUTO = {
  { 'telescope', 'telescope' },
  { 'fzf_lua', 'fzf-lua' },
  { 'snacks', 'snacks' },
  { 'mini', 'mini.pick' },
}

--- Backend name in use.
---@return string
function M.backend()
  local want = require('perforated.config').get().picker
  if want and want ~= 'auto' then
    return want
  end
  for _, b in ipairs(AUTO) do
    if has(b[2]) then
      return b[1]
    end
  end
  return 'select'
end

---@param spec perforated.PickSpec
function M.pick(spec)
  local name = M.backend()
  local fn = backends[name] or backends.select
  local ok, err = pcall(fn, spec)
  if not ok then
    require('perforated.core.debug').warn('picker', '%s failed: %s; falling back', name, err)
    backends.select(spec)
  end
end

M._backends = backends

return M
