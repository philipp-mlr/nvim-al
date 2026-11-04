# nvim-al

Business Central AL development in Neovim that behaves the way VS Code does:
diagnostics from the compiler and every configured analyzer, code actions,
go-to-definition into your own projects and into symbol packages, multi-project
workspaces from your `*.code-workspace` files, builds, publishing, tests and
debugging. No explorer, no picker, no other plugin required.

nvim-al runs the language server and debug adapter from Microsoft's AL Language
extension and talks to them the way VS Code does. How that works is written
down in [`docs/protocol.md`](docs/protocol.md).

**Status: pre-release.**

## Requirements

- Neovim ≥ 0.11
- .NET 10 with ASP.NET Core (`Microsoft.NETCore.App` and `Microsoft.AspNetCore.App` 10.x)
- The AL Language extension for VS Code, version 30.0 or newer: installed in
  VS Code, or an unzipped `.vsix` anywhere on disk
- Optional: [nvim-dap](https://github.com/mfussenegger/nvim-dap) for debugging

## Install

Any plugin manager, for example:

```lua
vim.pack.add({ "https://github.com/philipp-mlr/nvim-al" })
```

`setup()` is optional. Defaults work when the extension is installed in VS Code:

```lua
require("nvim-al").setup({
  extension_path = nil,  -- or an unzipped .vsix; also $NVIM_AL_EXTENSION
  analyzer_folder = nil, -- where ${analyzerFolder} points (e.g. ALCops DLLs)
})
```

Run `:checkhealth nvim-al`.

### Nix

The flake provides the plugin (`packages.<system>.default`) and a pinned AL
extension. The extension is unfree, so build it with your own nixpkgs, which
must allow unfree packages:

```nix
let
  nvim-al = inputs.nvim-al.packages.${pkgs.stdenv.hostPlatform.system}.default;
  al-extension = inputs.nvim-al.lib.mkAlExtension pkgs;
in
  # plugin: nvim-al; setup: extension_path = "${al-extension}",
  # dotnet = "${pkgs.dotnetCorePackages.aspnetcore_10_0}/bin/dotnet"
```

## How it finds your project

From the current file nvim-al walks up to the git root. The nearest `app.json`
is the project; the outermost `*.code-workspace` that lists it is the
workspace. One language server per workspace; the active project follows your
buffer. Settings come from the workspace file and `.vscode/settings.json`,
exactly as VS Code reads them. Worktrees work out of the box.

## Commands

| Command | |
|---|---|
| `:AL info` | toolchain, workspace, closure, effective settings |
| `:AL build` | build the current project; tells you which tracked files the build rewrote |
| `:AL restore` | put back the tracked files the last build rewrote |
| `:AL compile[!]` | compile the whole workspace (altool), results in quickfix |
| `:AL publish` | build and publish to the target; offers in-repo dependencies the target lacks |
| `:AL symbols [global]` | download symbols from the target or NuGet |
| `:AL test [id [method]\|file\|last]` | run tests; ✓/✗ signs and failure messages in the buffer |
| `:AL debug` | debug with nvim-dap (builds first for launch configurations) |
| `:AL log [op]` | output of the last build, compile, publish, symbols, test or debug run |
| `:AL target` | choose the launch configuration again |
| `:AL restart` | restart the language server |

## Repository hooks

Adapt nvim-al to a repository in its `.nvim.lua`, without touching the plugin:

```lua
require("nvim-al").setup({
  hooks = {
    compile = function(ctx)        -- replace :AL compile
      vim.cmd("botright split | terminal ./scripts/compile")
      return true
    end,
    launch = function(folder)      -- launch configurations from a script
      return vim.json.decode(vim.fn.system({ "./scripts/launch-config", folder.path }))
    end,
  },
})
```

See `:help nvim-al-hooks`.

## Credentials

`UserPassword` credentials come from `BC_SERVER_USERNAME`/`BC_SERVER_PASSWORD`
or are asked once per server and kept in memory. They are never written to
disk by nvim-al and never sent to the language server. One caveat: with
nvim-dap's log level at DEBUG or TRACE, nvim-dap logs the adapter environment,
password included, to `dap.log`. The default level does not.

## Scope

v1 supports on-prem and Docker environments (`UserPassword`, `Windows`
authentication). Entra ID / SaaS is planned. nvim-al does not bundle or
redistribute any Microsoft binaries.

## License

MIT
