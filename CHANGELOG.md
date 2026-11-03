# Changelog

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
