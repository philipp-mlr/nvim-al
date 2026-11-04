-- Colors for the AL language server's own semantic token types. Neovim colors
-- the standard LSP types (keyword, variable, parameter, ...) but not AL's
-- custom ones (localVariable, otherkeyword, builtinfunctions, ...), so those
-- tokens would show without a color, or worse, cover the treesitter color.
-- Each gets a default link to the closest treesitter group; a colorscheme that
-- defines the group itself wins (`default = true`).
local M = {}

-- token type -> treesitter group (the same scopes VS Code's AL theme uses)
M.links = {
  localVariable = "@variable",
  globalVariable = "@variable",
  returnparameter = "@variable.parameter",
  otherkeyword = "@keyword",
  preprocessorkeyword = "@keyword.directive",
  builtintypes = "@type.builtin",
  builtinfunctions = "@function.builtin",
  supportfunction = "@function.builtin",
  langaugeconstant = "@constant.builtin", -- sic, the server's spelling
  datetime = "@number",
  attribute = "@attribute",
  triggername = "@function",
  aleventcreation = "@function",
  aleventsubscription = "@function",
  tablefield = "@property",
  tablekey = "@property",
  tablefieldgroup = "@property",
  pagecontrol = "@property",
  pageaction = "@property",
  pageview = "@property",
  reportlabel = "@property",
  reportlayout = "@property",
  querydataitem = "@property",
  querycolumn = "@property",
  queryfilter = "@property",
  xmlporttableelement = "@property",
  xmlporttextelement = "@property",
  xmlportfieldelement = "@property",
  xmlportfieldattribute = "@property",
  punctuation = "@punctuation.delimiter",
  excludedCode = "@comment",
  xmlDocCommentText = "@comment.documentation",
  xmlDocCommentDelimiter = "@comment.documentation",
  xmlDocCommentName = "@tag",
  xmlDocCommentAttributeName = "@tag.attribute",
  xmlDocCommentAttributeQuotes = "@string",
  xmlDocCommentAttributeValue = "@string",
  xmlDocCommentCDataSection = "@comment.documentation",
  xmlDocCommentComment = "@comment",
  xmlDocCommentEntityReference = "@string.special",
  xmlDocCommentProcessingInstruction = "@comment.documentation",
  xmlLiteralAttributeName = "@tag.attribute",
  xmlLiteralAttributeQuotes = "@string",
}

local function apply()
  for token, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, "@lsp.type." .. token .. ".al", { link = target, default = true })
  end
end

--- Set the links now and again after every :colorscheme (which clears them).
function M.setup()
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("nvim-al-highlights", { clear = true }),
    callback = apply,
  })
end

return M
