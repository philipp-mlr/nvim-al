-- JSON as VS Code writes it: optional UTF-8 BOM, // and /* */ comments,
-- trailing commas. Everything is reduced to plain JSON, then vim.json.decode.
local M = {}

--- Remove comments and trailing commas, leaving strings untouched.
---@param s string
---@return string
local function strip(s)
  local out = {}
  local i, n = 1, #s
  local in_string = false
  -- index into `out` of a comma that is still a candidate for "trailing"
  local pending_comma = nil

  while i <= n do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if c == "\\" then
        out[#out + 1] = s:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      pending_comma = nil
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local e = s:find("\n", i, true) or (n + 1)
      i = e
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      local _, e = s:find("*/", i + 2, true)
      i = (e or n) + 1
    elseif c == "," then
      out[#out + 1] = c
      pending_comma = #out
      i = i + 1
    elseif c == "}" or c == "]" then
      if pending_comma then
        out[pending_comma] = ""
        pending_comma = nil
      end
      out[#out + 1] = c
      i = i + 1
    else
      if not c:match("%s") then
        pending_comma = nil
      end
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Decode VS Code-flavoured JSON. JSON null becomes nil.
---@param text string
---@return table|nil value
---@return string|nil err
function M.decode(text)
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  local ok, v = pcall(vim.json.decode, strip(text), { luanil = { object = true, array = true } })
  if not ok then
    return nil, tostring(v)
  end
  return v, nil
end

--- Read and decode a file.
---@param path string
---@return table|nil value
---@return string|nil err  "not found" when the file does not exist
function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "not found"
  end
  local text = f:read("*a")
  f:close()
  return M.decode(text)
end

return M
