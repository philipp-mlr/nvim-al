# nvim-al

Business Central AL development in Neovim that behaves the way VS Code does:
diagnostics from the compiler and all configured analyzers, code actions,
go-to-definition, multi-project workspaces from your `*.code-workspace` files,
builds and debugging. No explorer, no picker, no other plugin required.

**Status: pre-release.** See [`docs/specs`](docs/specs) for the design and
[`docs/protocol.md`](docs/protocol.md) for how it talks to the AL toolchain.

## Requirements

- Neovim ≥ 0.11
- .NET 10 runtime with ASP.NET Core (`Microsoft.NETCore.App` and `Microsoft.AspNetCore.App` 10.x)
- The AL Language extension for VS Code, version 30.0 or newer (installed in VS Code, or an unzipped `.vsix`)
- Optional: [nvim-dap](https://github.com/mfussenegger/nvim-dap) for debugging
