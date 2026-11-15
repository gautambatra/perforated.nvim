--- Entering a buffer while the poll runs: its file is asked about again only once it moved on
--- disk since its last fstat (`st.seen`: mtime and size taken just before it; your own saves
--- move it, checkout.lua). Loaded on the first such BufEnter (kept out of startup). The mode
--- isn't compared: `p4 edit` / `revert` elsewhere are the poll's `opened` query's to see.

local M = {}

--- Ask about the buffer's file again if it moved on disk since its last fstat.
---@param buf integer
---@param st perforated.BufState
---@param last_enter table<integer, integer>  poll.lua's throttle: a moved file's ask counts
function M.check(buf, st, last_enter)
  local buffer, seen = require('perforated.buffer'), st.seen
  vim.uv.fs_stat(st.path, function(_, s)
    local now = buffer.disk_sig(s and { sec = s.mtime.sec, nsec = s.mtime.nsec, size = s.size })
    vim.schedule(function()
      if buffer.get(buf) ~= st or st.seen ~= seen then
        return
      elseif now == seen.sig then
        return require('perforated.core.debug').debug(
          'poll',
          'buf %d %s: untouched since its fstat',
          buf,
          st.path
        )
      end
      last_enter[buf] = vim.uv.now()
      buffer.refresh(buf)
    end)
  end)
end

return M
