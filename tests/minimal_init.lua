-- Headless test init: repo + pinned mini.nvim on the runtimepath, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mini = root .. "/.deps/mini.nvim"
local MINI_COMMIT = "6d5a29e86a7352739506c28e0bc50fe214b5216f"

if vim.fn.isdirectory(mini) == 0 then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/echasnovski/mini.nvim",
    mini,
  })
  vim.fn.system({ "git", "-C", mini, "checkout", "--quiet", MINI_COMMIT })
end

vim.opt.runtimepath = { root, mini, vim.env.VIMRUNTIME }
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
package.path = root .. "/tests/?.lua;" .. package.path

require("mini.test").setup()
