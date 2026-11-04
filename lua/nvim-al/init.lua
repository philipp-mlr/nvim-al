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

--- State for statuslines.
---@param bufnr integer|nil
---@return { workspace: string|nil, folder: string|nil, loaded: boolean, building: boolean }
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = { workspace = nil, folder = nil, loaded = false, building = M._building == true }
  local lsp = require("nvim-al.lsp")
  local client = lsp.client_for(bufnr)
  local st = client and lsp.state(client.id)
  if st then
    out.workspace = st.ws.key
    out.loaded = st.loaded
    local name = vim.api.nvim_buf_get_name(bufnr)
    name = vim.uv.fs_realpath(name) or name
    local f = require("nvim-al.workspace").folder_for(st.ws, name)
    out.folder = f and f.path or nil
  end
  return out
end

--- A short statusline string: "AL Email" when ready, "AL Email …" while
--- loading, plus whatever is running ("Email: publishing to main-de (12s)").
--- Empty for buffers without an nvim-al client.
---@param bufnr integer|nil
---@return string
function M.statusline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local s = M.status(bufnr)
  if not s.workspace then
    return ""
  end
  local lsp = require("nvim-al.lsp")
  local client = lsp.client_for(bufnr)
  local st = client and lsp.state(client.id)
  local name = "AL"
  if s.folder and st then
    local f = require("nvim-al.workspace").folder_for(st.ws, s.folder)
    name = "AL " .. (f and f.name or vim.fs.basename(s.folder))
  end
  if not s.loaded then
    name = name .. " …"
  end
  local running = require("nvim-al.feedback").running()
  if #running > 0 then
    name = name .. " · " .. running[1]
  end
  return name
end

return M
