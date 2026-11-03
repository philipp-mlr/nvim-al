-- Quickfix items from AL compiler output and altool's JSON error logs.
local jsonc = require("nvim-al.jsonc")

local M = {}

local TYPES = { error = "E", warning = "W", info = "I", Error = "E", Warning = "W", Info = "I" }

--- Parse `<path>(<line>,<col>): <error|warning|info> <CODE>: <message>` lines,
--- optionally prefixed with `[OUT] `. Relative paths are resolved against base_dir.
---@param lines string[]
---@param base_dir string
---@return table[] quickfix items
function M.from_compiler_lines(lines, base_dir)
  local items = {}
  for _, line in ipairs(lines) do
    line = line:gsub("^%[OUT%]%s*", "")
    local path, lnum, col, kind, code, msg =
      line:match("^(.-)%((%d+),(%d+)%):%s+(%a+)%s+([%w]+):%s*(.*)$")
    if path and TYPES[kind] then
      if not (path:sub(1, 1) == "/" or path:match("^%a:[/\\]")) then
        path = base_dir .. "/" .. path
      end
      items[#items + 1] = {
        filename = vim.fs.normalize(path),
        lnum = tonumber(lnum),
        col = tonumber(col),
        type = TYPES[kind],
        text = code .. ": " .. msg,
      }
    end
  end
  return items
end

--- Items from one `*.errorLog.json` written by `altool workspace compile --errorlogdirectory`.
--- Issues suppressed in source are skipped. Unreadable files yield no items.
---@param path string
---@return table[] quickfix items
function M.from_error_log(path)
  local log = jsonc.read(path)
  if type(log) ~= "table" or type(log.issues) ~= "table" then
    return {}
  end
  local items = {}
  for _, issue in ipairs(log.issues) do
    local props = issue.properties or {}
    if props.isSuppressedInSource ~= "True" then
      local loc = (((issue.locations or {})[1] or {}).analysisTarget or {})[1] or {}
      local region = loc.region or {}
      local uri = loc.uri
      items[#items + 1] = {
        -- no location (e.g. AD0001 analyzer crashes): no filename, so quickfix
        -- does not attach the item to whatever buffer is current
        filename = (uri and uri ~= "") and vim.fs.normalize(uri) or nil,
        lnum = region.startLine or 1,
        col = region.startColumn or 1,
        end_lnum = region.endLine,
        end_col = region.endColumn,
        type = TYPES[props.severity] or "E",
        text = (issue.ruleId or "") .. ": " .. (issue.fullMessage or ""),
      }
    end
  end
  return items
end

return M
