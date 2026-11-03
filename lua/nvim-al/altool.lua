-- Run altool (from the AL extension) asynchronously with line-buffered output.
local toolchain = require("nvim-al.toolchain")

local M = {}

--- Feed raw chunks, get whole lines. Returns feed(chunk) and flush().
---@param on_line fun(line: string)
local function line_reader(on_line)
  local carry = ""
  local function feed(chunk)
    if not chunk then
      return
    end
    carry = carry .. chunk
    while true do
      local nl = carry:find("\n", 1, true)
      if not nl then
        break
      end
      on_line((carry:sub(1, nl - 1):gsub("\r$", "")))
      carry = carry:sub(nl + 1)
    end
  end
  local function flush()
    if carry ~= "" then
      on_line((carry:gsub("\r$", "")))
      carry = ""
    end
  end
  return feed, flush
end

M._line_reader = line_reader

---@class nvim_al.AltoolOpts
---@field cwd string
---@field env? table<string, string> extra environment variables
---@field on_line? fun(line: string, stream: "stdout"|"stderr")

--- Start `dotnet altool.dll <args>`. on_exit runs on the main loop with the
--- exit code and every output line (stdout and stderr interleaved per stream).
---@param args string[]
---@param opts nvim_al.AltoolOpts
---@param on_exit fun(code: integer, lines: string[])
---@return vim.SystemObj|nil
function M.run(args, opts, on_exit)
  local cfg = require("nvim-al").config()
  local cmd, err = toolchain.altool_cmd(cfg, args)
  if not cmd then
    require("nvim-al.util").notify(err, vim.log.levels.ERROR)
    return nil
  end
  local lines = {}
  local function sink(stream)
    return line_reader(function(line)
      lines[#lines + 1] = line
      if opts.on_line then
        vim.schedule(function()
          opts.on_line(line, stream)
        end)
      end
    end)
  end
  local out_feed, out_flush = sink("stdout")
  local err_feed, err_flush = sink("stderr")
  return vim.system(cmd, {
    cwd = opts.cwd,
    env = opts.env,
    text = true,
    stdout = function(_, data)
      out_feed(data)
    end,
    stderr = function(_, data)
      err_feed(data)
    end,
  }, function(res)
    out_flush()
    err_flush()
    vim.schedule(function()
      on_exit(res.code, lines)
    end)
  end)
end

return M
