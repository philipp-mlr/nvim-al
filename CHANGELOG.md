# Changelog

## 0.1.6

- Workspace symbols (`vim.lsp.buf.workspace_symbol()`, Telescope
  `lsp_dynamic_workspace_symbols`/`lsp_workspace_symbols`): objects of the
  workspace and its dependencies, plus procedures and fields when there is a
  query, from `al/symbolSearch`. The server's own `workspace/symbol` returned
  nothing. The symbol index is built in the background after loading.
- Type definition (`vim.lsp.buf.type_definition()`, Telescope
  `lsp_type_definitions`): from a variable to the object it is declared with.

## 0.1.5

- `textDocument/declaration` (`gD`, `vim.lsp.buf.declaration()`) goes to the
  definition. AL has no separate declaration; before, Neovim reported
  "method textDocument/declaration is not supported".
- The Nix package carries the real version (was 0.1.0).

## 0.1.4

Feedback: every long operation tells you what it is doing and why it failed.

- One progress message per operation, by phase: "Email: building",
  "compiling FO Base Application", "publishing to main-de", then
  "published to main-de in 31s". Workspace loading shows too.
  `require("nvim-al").statusline()` plus the `User NvimAlStatus` event.
- Failures say why: the server's reason (e.g. a missing dependency) instead
  of the last output line; full output in `:AL log [op]`.
- Publish offers in-repo dependencies the target lacks (or has in another
  version) and publishes them first, in dependency order.
- Publish, symbols, tests and debugging check the target first: unreachable,
  wrong instance, rejected credentials are reported before anything is built.
- Tests: ✓/✗ signs per `[Test]` procedure, failure messages as virtual text;
  `:AL test file`, `:AL test last`.
- Files not open in a buffer keep only warnings and errors
  (`diagnostics.workspace_min_severity`); opening a file shows all of its own.
- Builds that rewrite tracked files (report layouts, `*.g.xlf`) say which;
  `:AL restore` puts exactly those back.
- `:AL debug`: progress from checking to "attached, waiting for a session";
  launch configurations build first (the adapter's publish of a stale .app
  failed with "duplicate package ID"); failures show the server's reason
  instead of "see Visual Studio Code debug console".
- Fixed: diagnostics published for a bare path with `${workspaceFolder}`
  raised "URI must contain a scheme".
- Fixed: nvim-dap reported "Debug adapter didn't respond" while the .NET
  adapter was still starting (initialize timeout 30s).

## 0.1.3

- Removed a stray `result` symlink that broke the Nix plugin build.

## 0.1.2

- Flake: `lib.mkAlExtension pkgs` builds the pinned AL extension with your own
  nixpkgs (needed when that nixpkgs allows unfree packages).

## 0.1.1

- `<C-]>` jumps synchronously with a real tag entry, so the tag stack and `:pop` work.
- Symbol previews stay with the language server that produced them (two
  workspaces or worktrees open at once).
- The workspace a folder belongs to no longer depends on which project was
  opened first.
- Folders added to or removed from a saved `.code-workspace` are loaded without
  a restart (`al/didChangeWorkspaceFolders` + `al/loadManifest`).
- AL debug adapters left running are killed when Neovim exits.
- Documented that nvim-dap's DEBUG log contains the adapter environment.

## 0.1.0 (unreleased)

First release.

- Language server from the AL Language extension (≥ 30.0) with VS Code's
  workspace model: outermost `*.code-workspace`, per-folder settings,
  project-reference closure, active project follows the buffer.
- Diagnostics from the compiler and all configured analyzers, code actions,
  completion (labels normalised), hover, go to definition with read-only
  `al-preview://` buffers, references, rename, formatting.
- `:AL info`, `build`, `compile`, `publish`, `symbols`, `test`, `debug`,
  `target`, `restart`.
- Debugging with nvim-dap: attach/launch/snapshot configurations, AL events,
  credentials in memory only.
- Hooks for repository-specific behaviour.
- Nix flake: plugin package, pinned AL extension (`legacyPackages.al-extension`,
  unfree), unit tests as a flake check.
