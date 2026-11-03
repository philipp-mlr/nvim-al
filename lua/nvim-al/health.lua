-- :checkhealth nvim-al
local M = {}

function M.check()
  local h = vim.health
  local cfg = require("nvim-al").config()
  local tc = require("nvim-al.toolchain")

  h.start("nvim-al: toolchain")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 required")
  end

  local ext, err = tc.find_extension(cfg)
  if ext then
    h.ok(("AL extension %s at %s"):format(ext.version, ext.path))
  else
    h.error(err or "AL extension not found")
  end
  for _, s in ipairs(tc.skipped()) do
    h.info(("skipped %s: %s"):format(s.path, s.reason))
  end

  local dotnet, derr = tc.dotnet(cfg)
  if dotnet then
    h.ok("dotnet: " .. dotnet)
    local ok, rerr = tc.check_runtime(cfg)
    if ok then
      h.ok("Microsoft.NETCore.App and Microsoft.AspNetCore.App 10.x present")
    else
      h.error(rerr)
    end
  else
    h.error(derr)
  end

  if pcall(require, "dap") then
    h.ok("nvim-dap found (debugging available)")
  else
    h.info("nvim-dap not found (debugging unavailable)")
  end

  h.start("nvim-al: current buffer")
  -- :checkhealth opens its own buffer; report the buffer the user came from.
  local alt = vim.fn.bufnr("#")
  local buf = (alt > 0 and vim.bo[alt].buftype == "") and alt or 0
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    h.info("no file in the current buffer")
    return
  end
  local ws, reason = require("nvim-al.workspace").resolve(name, {
    workspace_file = cfg.hooks.workspace_file,
  })
  if not ws then
    h.info(("%s: %s"):format(vim.fn.fnamemodify(name, ":~"), reason))
    return
  end
  h.ok(("workspace: %s (%d folders)"):format(ws.file or "single folder " .. ws.key, #ws.folders))
  local folder = require("nvim-al.workspace").folder_for(ws, name)
  if folder then
    h.ok(("project: %s (%s)"):format(folder.name, folder.path))
  end
end

return M
