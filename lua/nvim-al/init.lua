local M = {}

---@type nvim_al.Config|nil
local current

--- Configure nvim-al. Safe to call more than once; the last call wins.
---@param opts table|nil
function M.setup(opts)
  current = require("nvim-al.config").merge(opts)
end

--- The active configuration (defaults when setup() was never called).
---@return nvim_al.Config
function M.config()
  if not current then
    current = require("nvim-al.config").merge({})
  end
  return current
end

return M
