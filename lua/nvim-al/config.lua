local util = require("nvim-al.util")

local M = {}

---@class nvim_al.Hooks
---@field workspace_file? fun(project: string, candidates: string[]): string|nil
---@field settings? fun(folder: nvim_al.Folder, settings: table): table|nil
---@field build? fun(ctx: table): boolean|nil
---@field compile? fun(ctx: table): boolean|nil
---@field publish? fun(ctx: table): boolean|nil
---@field test? fun(ctx: table): boolean|nil
---@field launch? fun(folder: nvim_al.Folder): table[]|nil

---@class nvim_al.Config
---@field extension_path string|nil override toolchain discovery
---@field dotnet string dotnet executable
---@field analyzer_folder string|nil absolute dir substituted for ${analyzerFolder}
---@field settings table<string, any> user-level al.* settings
---@field hooks nvim_al.Hooks

---@type nvim_al.Config
M.defaults = {
  extension_path = nil,
  dotnet = "dotnet",
  analyzer_folder = nil,
  settings = {},
  hooks = {},
}

local known = {
  extension_path = true,
  dotnet = true,
  analyzer_folder = true,
  settings = true,
  hooks = true,
}

--- Defaults merged with user options. Keys starting with "_" are test-only and
--- pass through. Unknown keys produce a warning.
---@param user table|nil
---@return nvim_al.Config
function M.merge(user)
  user = user or {}
  local unknown = {}
  for k in pairs(user) do
    if not known[k] and not tostring(k):match("^_") then
      unknown[#unknown + 1] = tostring(k)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    util.notify("unknown setup option(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user)
  cfg.settings = cfg.settings or {}
  cfg.hooks = cfg.hooks or {}
  return cfg
end

return M
