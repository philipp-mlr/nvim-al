# Changelog

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
