-- Project references and the dependency closure of a workspace folder
-- (docs/protocol.md §2.5). Pure functions over the folders' manifests.
local M = {}

local function same_identity(dep, m)
  return (dep.id or ""):lower() == (m.id or ""):lower()
    and dep.name == m.name
    and dep.publisher == m.publisher
    and dep.version == m.version
end

--- Other workspace folders whose app.json identity matches a dependency of `folder`.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@return nvim_al.Folder[]
function M.references(ws, folder)
  local refs = {}
  if not folder.manifest then
    return refs
  end
  for _, dep in ipairs(folder.manifest.dependencies or {}) do
    for _, other in ipairs(ws.folders) do
      if other ~= folder and other.manifest and same_identity(dep, other.manifest) then
        refs[#refs + 1] = other
        break
      end
    end
  end
  return refs
end

--- `folder` first, then its transitive project references, depth-first, each once.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@return string[] paths
function M.closure(ws, folder)
  local out, seen = {}, {}
  local function visit(f)
    if seen[f.path] then
      return
    end
    seen[f.path] = true
    out[#out + 1] = f.path
    for _, r in ipairs(M.references(ws, f)) do
      visit(r)
    end
  end
  visit(folder)
  return out
end

return M
