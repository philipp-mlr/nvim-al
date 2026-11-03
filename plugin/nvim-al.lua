if vim.g.loaded_nvim_al then
  return
end
vim.g.loaded_nvim_al = true

vim.filetype.add({ extension = { al = "al", dal = "al" } })

local group = vim.api.nvim_create_augroup("nvim-al", { clear = true })

local function attach(args)
  if vim.bo[args.buf].buftype ~= "" then
    return
  end
  require("nvim-al.lsp").attach(args.buf)
end

vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "al", callback = attach })

-- BufEnter switches the active project when moving between already attached buffers.
vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  pattern = { "*.al", "*.dal" },
  callback = function(args)
    if vim.bo[args.buf].filetype == "al" then
      attach(args)
    end
  end,
})

-- app.json gets diagnostics too (VS Code's document selector includes json),
-- but only inside a resolvable AL workspace.
vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "json", "jsonc" },
  callback = function(args)
    if vim.fs.basename(vim.api.nvim_buf_get_name(args.buf)) == "app.json" then
      attach(args)
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = { "app.json", "*.code-workspace", "*/.vscode/settings.json" },
  callback = function(args)
    require("nvim-al.lsp").on_project_file_written(args.match)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["nvim-al.lsp"] then
      require("nvim-al.lsp").stop_all()
    end
  end,
})
