-- :AL <subcommand>
local util = require("nvim-al.util")

local M = {}

local function cur()
  return vim.api.nvim_get_current_buf()
end

local function info()
  local nvim_al = require("nvim-al")
  local cfg = nvim_al.config()
  local tc = require("nvim-al.toolchain")
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  local ext, err = tc.find_extension(cfg)
  add("AL extension: " .. (ext and (ext.version .. "  " .. ext.path) or ("not found: " .. err)))
  add("dotnet:       " .. (tc.dotnet(cfg) or "not found"))
  local name = vim.api.nvim_buf_get_name(cur())
  name = vim.uv.fs_realpath(name) or name
  local ws, reason =
    require("nvim-al.workspace").resolve(name, { workspace_file = cfg.hooks.workspace_file })
  if not ws then
    add("workspace:    none (" .. tostring(reason) .. ")")
  else
    add("workspace:    " .. (ws.file or ("single folder " .. ws.key)))
    add("git root:     " .. ws.root)
    local folder = require("nvim-al.workspace").folder_for(ws, name)
    local lsp = require("nvim-al.lsp")
    local client = lsp.client_for(cur())
    local st = client and lsp.state(client.id)
    add(
      "server:       "
        .. (
          client
            and ("running (id " .. client.id .. ", loaded: " .. tostring(st and st.loaded) .. ")")
          or "not running"
        )
    )
    add("active:       " .. tostring(st and st.active))
    add("")
    add("folders:")
    for _, f in ipairs(ws.folders) do
      add(
        ("  %2d %s %s%s"):format(
          f.index,
          f == folder and "*" or " ",
          f.name,
          f.manifest and "" or "  (no app.json)"
        )
      )
    end
    if folder then
      add("")
      add("closure of " .. folder.name .. ":")
      for _, p in ipairs(require("nvim-al.closure").closure(ws, folder)) do
        add("  " .. p)
      end
      add("")
      add("settings of " .. folder.name .. ":")
      local s = require("nvim-al.settings").resolve(ws, folder, cfg)
      local keys = vim.tbl_keys(s)
      table.sort(keys)
      for _, k in ipairs(keys) do
        add(("  %s = %s"):format(k, vim.inspect(s[k], { newline = " ", indent = "" })))
      end
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end

local subcommands = {
  info = { run = info },
  build = {
    run = function()
      require("nvim-al.build").build(cur())
    end,
  },
  compile = {
    run = function(_, bang)
      require("nvim-al.build").compile(cur(), { show_log = bang })
    end,
  },
  publish = {
    run = function()
      require("nvim-al.targets").publish(cur())
    end,
  },
  symbols = {
    run = function(args)
      require("nvim-al.targets").symbols(cur(), { global = args[1] == "global" })
    end,
    complete = { "global" },
  },
  test = {
    run = function(args)
      local t = require("nvim-al.targets")
      if args[1] == "file" or args[1] == "last" then
        return t.test(cur(), { scope = args[1] })
      end
      local id = tonumber(args[1])
      t.test(cur(), id and { codeunit = id, method = args[2] } or nil)
    end,
    complete = { "file", "last" },
  },
  debug = {
    run = function()
      require("nvim-al.dap").debug()
    end,
  },
  target = {
    run = function()
      local ctx = require("nvim-al.build").context(cur())
      if not ctx then
        return
      end
      -- also drops cached credentials of the old target (e.g. a mistyped password)
      require("nvim-al.launch").forget(ctx.folder.path, function(old)
        require("nvim-al.credentials").forget(old)
      end)
      require("nvim-al.launch").target(ctx.ws, ctx.folder, ctx.cfg, function(t)
        if t then
          util.notify("target for " .. ctx.folder.name .. ": " .. t.name)
        end
      end)
    end,
  },
  log = {
    run = function(args)
      require("nvim-al.feedback").open(args[1])
    end,
    complete = { "build", "compile", "publish", "symbols", "test", "debug" },
  },
  restore = {
    run = function()
      require("nvim-al.build").restore()
    end,
  },
  restart = {
    run = function()
      require("nvim-al.lsp").restart_buffer(cur())
    end,
  },
}

---@return string[]
function M.names()
  local n = vim.tbl_keys(subcommands)
  table.sort(n)
  return n
end

--- Command-line completion for :AL.
function M.complete(arglead, cmdline, _)
  local words = vim.split(cmdline, "%s+", { trimempty = false })
  if #words <= 2 then
    return vim.tbl_filter(function(n)
      return n:sub(1, #arglead) == arglead
    end, M.names())
  end
  local sub = subcommands[words[2]]
  return vim.tbl_filter(function(n)
    return n:sub(1, #arglead) == arglead
  end, (sub and sub.complete) or {})
end

--- :AL entry point.
function M.run(opts)
  local args = vim.split(opts.args or "", "%s+", { trimempty = true })
  local name = table.remove(args, 1)
  local sub = subcommands[name or ""]
  if not sub then
    return util.notify(
      ("unknown subcommand '%s'; valid: %s"):format(name or "", table.concat(M.names(), ", ")),
      vim.log.levels.ERROR
    )
  end
  sub.run(args, opts.bang)
end

return M
