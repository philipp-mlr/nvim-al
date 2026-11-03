local M = {}

local is_windows = vim.fn.has("win32") == 1

--- Normalised absolute-style path without a trailing slash ("/" stays "/").
---@param path string
---@return string
function M.normalize(path)
  local p = vim.fs.normalize(path)
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  return p
end

local function key(path)
  local p = M.normalize(path)
  return is_windows and p:lower() or p
end

--- Path equality; case-insensitive on Windows only.
---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  return key(a) == key(b)
end

--- True when `path` is `dir` or below it.
---@param path string
---@param dir string
---@return boolean
function M.is_inside(path, dir)
  local p, d = key(path), key(dir)
  if p == d then
    return true
  end
  if d == "/" then
    return p:sub(1, 1) == "/"
  end
  return p:sub(1, #d + 1) == d .. "/"
end

--- Whole file as a string, or nil when it cannot be read.
---@param path string
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---@param msg string
---@param level? integer vim.log.levels.*
function M.notify(msg, level)
  vim.notify("nvim-al: " .. msg, level or vim.log.levels.INFO)
end

local seen = {}

--- Notify at most once per `id` for the session.
---@param id string
---@param msg string
---@param level? integer
function M.notify_once(id, msg, level)
  if seen[id] then
    return
  end
  seen[id] = true
  M.notify(msg, level)
end

return M
