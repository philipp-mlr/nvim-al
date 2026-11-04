local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.highlights"] = nil
    end,
  },
})

local function link(name)
  return vim.api.nvim_get_hl(0, { name = name }).link
end

T["AL token types without a Neovim default get a color"] = function()
  require("nvim-al.highlights").setup()
  eq(link("@lsp.type.localVariable.al"), "@variable")
  eq(link("@lsp.type.globalVariable.al"), "@variable")
  eq(link("@lsp.type.otherkeyword.al"), "@keyword")
  eq(link("@lsp.type.builtinfunctions.al"), "@function.builtin")
  eq(link("@lsp.type.builtintypes.al"), "@type.builtin")
  eq(link("@lsp.type.langaugeconstant.al"), "@constant.builtin")
  eq(link("@lsp.type.tablefield.al"), "@property")
  eq(link("@lsp.type.xmlDocCommentText.al"), "@comment.documentation")
  eq(link("@lsp.type.excludedCode.al"), "@comment")
end

T["a colorscheme's own choice wins; links come back after :colorscheme"] = function()
  vim.api.nvim_set_hl(0, "@lsp.type.otherkeyword.al", { fg = "#ff0000" })
  require("nvim-al.highlights").setup()
  eq(vim.api.nvim_get_hl(0, { name = "@lsp.type.otherkeyword.al" }).fg, 0xff0000)
  vim.cmd("highlight clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  eq(link("@lsp.type.otherkeyword.al"), "@keyword")
end

return T
