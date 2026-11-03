# nvim-al design

Status: draft, 2026-11-03

## Intent

Business Central AL development in Neovim that behaves the way VS Code does,
without VS Code's UI and without other plugins dictating your setup.

AL codebases are organised around VS Code workspaces (`*.code-workspace`) and
per-folder `.vscode/` settings. Those are a fact of life: colleagues use VS Code,
and CI reads the same files. nvim-al reads them as they are. Open any `.al`
file anywhere in a repository or worktree and the right project, dependency
closure, analyzers and ruleset are active, with no explorer, workspace picker
or panel.

Existing plugins and what we take from them:

- **al.nvim** (abonckus): a sound multi-project model (closure from `app.json`),
  but it depends on `code-workspace.nvim` and prescribes a file explorer. We
  take the closure logic, not the coupling.
- **ALNvim** (drs76): a careful list of server quirks and robustness lessons,
  wrapped in a large UI (Telescope pickers, wizards, colour schemes, MCP). We
  take the lessons, not the UI.
- **The VS Code AL extension**: the ground truth. Its observed behaviour is
  written down in [`docs/protocol.md`](../protocol.md); nvim-al implements
  that document.

## Goals

1. **Language features with VS Code parity**: diagnostics (compiler plus all
   configured analyzers, whole project in the background), code actions,
   completion, hover, go-to-definition (including symbol-package previews),
   references, rename, formatting, signature help, symbols.
2. **Multi-project workspaces**: the active project follows the current
   buffer; dependency closure from `app.json`; switching is automatic and
   silent.
3. **Settings exactly as VS Code resolves them**, from the `.code-workspace`
   file and `.vscode/settings.json`.
4. **Builds**: build the current project; compile the whole workspace;
   errors go to the quickfix list.
5. **Debugging, fully supported** through nvim-dap: launch, attach and
   snapshot configurations from `.vscode/launch.json`, credentials, the
   AL-specific debug events.
6. **Publish, symbols and tests** as commands.
7. **Works in any AL repository** and in any git worktree of it.
8. **Self-contained**: no dependency on repository-specific tools (such as
   bc-apps' `bcdev`). Repositories adapt it through hooks (see *Extension
   points*).

## Non-goals

- UI: no explorers, pickers, wizards, dashboards, colour schemes or statusline
  components beyond a small state API. Neovim's own `vim.ui.select`,
  `vim.ui.input`, quickfix and `vim.notify` are the UI.
- MCP servers (`launchmcpserver` and friends).
- **In v1:** SaaS / Entra ID authentication (`AAD`, `MicrosoftEntraID`,
  `altool auth login`, device-code sign-in outside the debugger). v1 supports
  `UserPassword` (on-prem, Docker) and `Windows`. The `credentials` module is
  keyed by target and authentication type so Entra ID can be added in v2
  without reshaping it. Configurations with other authentication types are
  rejected with a clear message.
- Snippets, syntax highlighting, filetype grammar. Tree-sitter-al and snippet
  engines exist; nvim-al only sets `filetype=al` for `*.al` and `*.dal`.
- Native per-platform AL extensions (≤ 18.0.2293710).
- The altool language server (`launchlspserver`) as a backend: no diagnostics,
  no code actions (see protocol §1).
- Bundling or redistributing Microsoft binaries.

## Anti-goals

- **A second workspace model.** If nvim-al ever disagrees with VS Code about
  which project, settings or analyzers apply, that is a bug in nvim-al, not a
  feature.
- **Requiring a specific plugin manager, file explorer, completion engine or
  picker.** Hard dependencies: Neovim and, for debugging only, nvim-dap.
- **Silent magic.** Every resolution (which workspace file, which settings,
  which extension) must be explainable with one command (`:checkhealth nvim-al`
  plus `:AL info`).

## Constraints

- Neovim ≥ 0.11 (`vim.lsp.config`/`vim.lsp.enable`, `vim.fs.root`, `vim.uv`).
- .NET 10 runtime with ASP.NET Core (`dotnet` on `PATH` or configured).
- AL extension **≥ 30.0** (dotnet layout, bundled `altool` with
  `downloadsymbols`, `runtests`, `publishapp`), obtained by the user: a VS Code
  install, a downloaded `.vsix`, or a package manager (Nix). nvim-al locates it
  and never downloads it. Older extensions are refused with a clear message in
  `:checkhealth`. *(Builder-check call: one tested version line instead of a
  matrix back to 18.x; the protocol was observed on 30.0.)*
- Must run on Linux and macOS. Windows support is wanted but tested second
  (see *Platforms*).
- Pure Lua, no compiled helper. The Go DAP proxy in al.nvim is unnecessary:
  the adapter speaks plain DAP over stdio (verified).
- Public repository from day one. `docs/protocol.md` describes behaviour in our
  own words and contains no Microsoft code.

## Approaches considered

| | A. Port al.nvim, drop coupling | B. altool LSP + compile-on-save | **C. Implement the VS Code protocol directly (chosen)** |
|---|---|---|---|
| Diagnostics while typing | yes | no (only after save, via compiler) | yes |
| Code actions | yes | no | yes |
| Workspace logic | inherited, tied to code-workspace.nvim's model | built into the server | our own, ~small, following protocol §2.3–2.5 |
| Debugging | Go proxy | not available | plain DAP, verified |
| Cost | untangling someone else's architecture | low, but permanently below VS Code | moderate, clean |

**B** fails goal 1. **A** would mean starting from a design we explicitly
don't want and then removing it piece by piece. **C** is chosen: the protocol
is now documented and verified end to end, so implementing it directly is
smaller than adapting either existing plugin.

## Architecture

One Lua package, `lua/nvim-al/`, modules in dependency order. Each has one job
and can be tested without Neovim's UI.

| Module | Job |
|---|---|
| `toolchain` | Find the AL extension and `dotnet`. The **single** resolver for every binary path (`host`, `alc`, `altool`, built-in analyzer dir). Order: `setup({ extension_path })` → `$NVIM_AL_EXTENSION` → newest usable `ms-dynamics-smb.al-*` under the usual VS Code extension directories. "Usable" = dotnet layout and runtime found. |
| `jsonc` | Parse VS Code JSON with comments and trailing commas. |
| `workspace` | Given a path: find the **workspace file** and its folders, or fall back to a single folder. Read and cache each folder's `app.json` (BOM-tolerant). Invalidate on write of `app.json` / workspace file. |
| `closure` | Project references and transitive closure (protocol §2.5). Pure functions over manifests. |
| `settings` | Resolve `al.*` settings per folder with VS Code precedence (protocol §2.4) and build `WorkspaceSettings`. Applies the `settings` hook last. |
| `lsp` | Start one EditorServices client per workspace (per workspace file, or per single folder). Startup sequence, active-folder switching on `BufEnter` (guarded on folder change, debounced), server→client request handlers, `al/gotodefinition` and `al-preview://` buffers, code-action command execution. |
| `build` | `:AL build` via `al/createPackage`; `:AL compile` via `altool workspace compile` with analyzers and ruleset passed explicitly (protocol §4), structured error logs → quickfix. Both overridable by hooks. |
| `launch` | Read `.vscode/launch.json` (folder, then workspace `launch` section), pick a configuration, resolve it as VS Code does (protocol §3.2). |
| `credentials` | Prompt for UserPassword credentials, keep them in memory per (server, instance, tenant) for the session, hand them to the adapter/altool via environment. Never written to disk, never sent to the language server. |
| `dap` | Register the nvim-dap adapter (`dotnet host /startDebugging … /projectRoot:<folder>`, cwd = folder, credentials in env) and configuration provider from `launch`. Re-arm breakpoints on every `initialized`, handle `al/openUri` and `al/deviceLogin`, kill adapters on exit. Loaded only if nvim-dap is present. |
| `commands` | `:AL <subcommand>` with completion. |
| `health` | `:checkhealth nvim-al`. |

### Workspace discovery

From the buffer's directory, walk upwards **until the git root** (the
directory containing `.git` — a file in worktrees, a directory otherwise), and
stop there. On the way collect:

1. the nearest `app.json` → the buffer's **project folder**;
2. every `*.code-workspace` file whose `folders` include that project folder.

Choose the workspace file:

- exactly one → use it;
- several → the **outermost** one, closest to the git root (the
  "all projects" file), unless the `workspace_file` hook decides. Ties at the
  same depth: alphabetical, with a one-time notice;
- none → **single-folder mode**: the project folder is the only workspace
  folder, settings come from its `.vscode/settings.json` and user settings.

The choice is cached per project folder and shown in `:AL info`. Paths inside a
workspace file are relative to that file, so every worktree resolves to its own
checkout.

Example (bc-apps): `apps/Email/app/src/X.al` → project `apps/Email/app`;
`apps/Email/Email.code-workspace` and `apps/Apps.code-workspace` both list it;
`apps/Apps.code-workspace` is closer to the git root and wins. One server
then covers all 49 folders.

### Language server lifecycle

- One client per workspace (keyed by workspace file path, or folder path in
  single-folder mode). Started on the first AL buffer in it.
- `initialize` with all workspace folders, then `al/loadManifest` for each
  folder with an `app.json`, then `setActiveWorkspace` for the buffer's folder.
- On `BufEnter` of an AL buffer: if its folder differs from the client's active
  folder, re-send the active workspace sequence. Debounced (~100 ms).
- On write of `app.json`: reload that manifest, clear closure caches, re-send if
  it affects the active closure.
- On write of the workspace file or a `.vscode/settings.json`: re-resolve
  settings and send them.
- Also attach to `app.json` / `*.json` buffers inside workspace folders (VS Code
  includes `json` in the document selector) so `app.json` gets diagnostics.
- On `VimLeavePre`: stop clients and kill their process trees.
- Completion items: normalise non-string labels before handing them to the
  client (reported by ALNvim; re-verify against the current server before
  adding the shim).

### Settings resolution

Per folder, merged in this order (later wins): built-in defaults from the
extension's `package.json` schema → user settings → workspace file `settings` →
folder `.vscode/settings.json`.

"User settings" means `setup({ settings = { ["al.xxx"] = … } })`. nvim-al does
**not** read VS Code's user `settings.json` (it lives in a different place on
every OS, and Neovim users configure in Lua).

Values are passed through unresolved, as VS Code does (`${workspaceFolder}`,
`${CodeCop}`, `${analyzerFolder}` are expanded by the server). One exception,
because a read-only extension directory cannot receive downloaded analyzers:
`setup({ analyzer_folder = "<dir>" })`. When set, `${analyzerFolder}`
entries in `al.codeAnalyzers` are rewritten to that absolute directory. Built-in
`${CodeCop}` etc. are never rewritten.

### Builds

- `:AL build` uses the server's own build of the active project (`al/createPackage`),
  so it uses exactly the settings the server already has. Result as
  notification, errors in diagnostics and quickfix.
- `:AL compile` compiles the whole workspace with `altool workspace compile`.
  altool ignores the workspace file's `al.*` settings, so nvim-al passes
  package cache, ruleset and analyzers explicitly, mapping `${CodeCop}` etc.
  to `--analyzers` and the rest to `--customanalyzers`. Output and the JSON
  error logs are parsed into quickfix. Streams are read line-buffered.
  Single-folder mode compiles that folder only.

Settings can differ per folder, but `altool workspace compile` takes analyzers
and ruleset once for the whole workspace. v1 runs **once** with the
workspace-level settings (`.code-workspace` `settings` over user settings) and
warns, listing the folders whose effective analyzers or ruleset differ.
Grouping into several runs is a later option if it is ever needed. Repositories
that need exact per-folder compiles use the `compile` hook.

### Debugging

- Configurations: `.vscode/launch.json` of the active folder, then the
  workspace file's `launch.configurations`. Provided to nvim-dap through a
  configuration provider. A single matching configuration needs no picker.
- Before `launch` (which publishes): save modified AL buffers of the project.
  The adapter publishes; nvim-al does not build first.
- Adapter: `dotnet <host> /startDebugging [server options] /projectRoot:<folder>`,
  **cwd = folder**, environment = editor env plus credentials.
- Credentials: if the configuration uses `UserPassword` and
  `BC_SERVER_USERNAME`/`BC_SERVER_PASSWORD` are not set, prompt
  (`vim.ui.input`, password masked with `inputsecret()`), cache in memory for
  the session.
- Breakpoints: re-send on every `initialized` event (nvim-dap does this; nvim-al
  verifies it in tests).
- Events: `al/openUri` → `vim.ui.open`; `al/deviceLogin` → notify the code and
  open the URI.
- `al-preview://` buffers during a debug session: fetch through the session
  (`al/previewDocument` as a DAP custom request).
- One adapter per environment: before starting, warn if an nvim-al adapter for
  the same server/instance is still running; kill all adapters on exit.
- Snapshot debugging: `snapshotInitialize` works through the same adapter; the
  related commands (finish snapshot, open snapshot) are v2.

### Publish, symbols, tests

All through the bundled **altool**, never through the language server, so the
language server never needs credentials. *(Builder-check call: VS Code sends
credentials to the server, which stores them in an encrypted file next to the
host binary. That conflicts with "never on disk" and fails on read-only
installs. altool takes them from the environment instead.)*

One **target** is shared by `dap`, publish, symbols and tests: the launch
configuration picked for the project (from `launch.json`, the workspace file
or the `launch` hook). The first command that needs a target asks if there are
several, then remembers the choice per project for the session (`:AL target`
changes it). nvim-al passes the target to altool **explicitly**
(`--server`, `--port`, `--serverinstance`, `--tenant`, `--authentication`,
`--environmenttype`, `--environmentname`) instead of letting altool read
`launch.json`, so a hook-provided target behaves the same as a file-based one.

- `:AL publish`: `:AL build`, then `altool publishapp <app> --project <folder>` + target flags.
- `:AL symbols`: `altool downloadsymbols --project <folder>` + target flags
  (or `--globalsourcesonly`), then tell the language server to reload
  (re-send the active workspace).
- `:AL test [codeunit [method]]`: `altool runtests --project <folder>` +
  target flags, JSON output → quickfix/notify. Default: the test codeunit and
  method at the cursor. It does **not** publish first: run `:AL publish` (or
  debug-launch) for the test app before. *(Builder-check call: keeps `:AL test`
  fast and predictable; a `test` hook can chain publish if a repository wants it.)*

### Extension points

`setup()` options for common needs, plus a `hooks` table for repository-specific
behaviour. Hooks are plain Lua functions. Repositories ship them in a trusted
`.nvim.lua` (Neovim's `exrc`), which nvim-al does not need to know about.

```lua
require("nvim-al").setup({
  extension_path = nil,     -- override toolchain discovery
  dotnet = "dotnet",
  analyzer_folder = nil,    -- absolute dir for ${analyzerFolder}
  settings = {},            -- user-level al.* settings
  hooks = {
    workspace_file = nil,   -- fn(project_folder, candidates) -> path|nil
    settings = nil,         -- fn(folder, settings) -> settings
    build = nil,            -- fn(ctx) -> handled?  (replace :AL build)
    compile = nil,          -- fn(ctx) -> handled?  (replace :AL compile)
    publish = nil,          -- fn(ctx) -> handled?
    test = nil,             -- fn(ctx) -> handled?
    launch = nil,           -- fn(folder) -> list of launch configurations (instead of launch.json)
  },
})
```

Example: bc-apps could route `:AL compile`/`:AL test` to `bcdev`, and provide
launch configurations from `bcdev status --json`, in its own `.nvim.lua`. That
code belongs in bc-apps, not here.

### Commands

`:AL info` (resolved toolchain, workspace file, folders, active folder,
closure, effective settings), `:AL build`, `:AL compile`, `:AL publish`,
`:AL symbols`, `:AL test`, `:AL restart`. Debugging uses nvim-dap's own commands.
Further al.nvim-style commands (event publishers, permission sets, symbol
search) are later additions on the same request plumbing.

### State API

`require("nvim-al").status(bufnr)` → `{ workspace, folder, loaded, building }`
for statuslines. No statusline component of our own.

## Platforms

Linux first (primary user, NixOS). macOS should work unchanged (same dotnet
binaries). Windows: plan for it in path handling (`vim.fs.normalize`,
case-insensitive path comparison, drive letters in `file://` URIs) and in
toolchain discovery (`%USERPROFILE%\.vscode\extensions`), but it is verified
after Linux works. The protocol document notes a few Windows quirks
(user-profile paths, `.exe` hosts in old layouts).

## Testing

- Unit tests (busted or mini.test, builder's choice) for `jsonc`, `workspace`,
  `closure`, `settings`, `launch` resolution, quickfix parsers, using fixture
  repositories with workspace files, nested `app.json`, worktree-style `.git`
  files.
- Integration tests behind an environment flag: start the real EditorServices
  host against a small fixture AL project with a local package cache, and check
  that diagnostics arrive, that the active folder switches, that a code action
  applies, and that `al/gotodefinition` jumps. They need the extension and
  Microsoft symbols, which the public repository does not contain. They run
  **locally only**: the developer points `NVIM_AL_TEST_EXTENSION` and
  `NVIM_AL_TEST_PACKAGES` at their own copies (`altool downloadsymbols
  --globalsourcesonly` fills the cache without a server). CI runs unit tests
  only. *(Builder-check call.)*
- Debugging: a manual checklist (attach, breakpoint, stack, variables,
  evaluate, step, launch with publish), run against a real BC environment
  before each release.

## Distribution

- Plain Neovim plugin layout (`lua/`, `plugin/`, `doc/nvim-al.txt`), installable
  with any plugin manager or `vim.pack`.
- A Nix flake exposing the plugin, and optionally a derivation for the AL
  extension from a pinned `.vsix` hash for users who want it. The derivation
  fetches from Microsoft at build time; the repository never contains the
  binaries.
- MIT licence.

## Decided in conversation

- Not tied to bc-apps; bc-apps is the first real test case.
- Workspace files are read, not avoided: the top-level all-projects workspace
  is the normal case.
- No dependency on `bcdev` or any other repository tool.
- No MCP.
- Debugging is a first-class goal.
- Diagnostics follow VS Code (EditorServices), found by reverse engineering
  and verified by probes.
- Name `nvim-al`, public repository under `github.com/philipp-mlr`.
- v1 authentication: on-prem/Docker (`UserPassword`, `Windows`); Entra ID in v2.
- Several matching workspace files: the outermost wins.
- `:AL compile`: one altool run with workspace settings, warning on folders
  that differ.

## Calls made during the builder check

Marked inline with *(Builder-check call)*: extension ≥ 30.0 only; publish,
symbols and tests through altool with explicit target flags, so credentials
never reach the language server; one shared, remembered target per project;
`:AL test` does not publish; integration tests run locally only.

## Left to the builder

- Module internals, file layout below `lua/nvim-al/`, test framework.
- Debounce timings, caching strategy, notification wording.
- Exact quickfix formatting.
- Whether `:AL compile` runs folder groups in parallel.

## Open questions

None blocking. Revisit after v1: reading VS Code's user `settings.json`, Entra
ID, grouped workspace compiles, snapshot-debugging commands.
