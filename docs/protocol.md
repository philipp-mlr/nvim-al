# AL editor protocol notes

How the Microsoft AL toolchain talks to an editor, as observed on Linux.
This is the reference nvim-al is built against.

The notes are written in our own words. They describe *behavior*: process
arguments, message names, payload shapes and their order. They contain no
Microsoft code. Sources: watching the messages the VS Code AL extension sends
(its bundled client, `dist/extension.js`, and the setting schema in its
`package.json`), and probing the language server and debug adapter directly
with small scripted clients.

Observed with AL extension **30.0.2863738** (vsix) and `Microsoft.Dynamics.BusinessCentral.Development.Tools`
**18.1.43** / **30.0.44-beta** (NuGet), on Linux with .NET 10.0.12, against a
Business Central 28.3 dev environment running in Docker. Microsoft can change
any of this without notice. When an extension update breaks something, this
document is the first thing to re-verify.

## 1. What ships where

The VS Code extension (`ms-dynamics-smb.al`, a `.vsix`, which is a zip) contains
everything an editor needs in `extension/bin/`:

| File | Purpose |
|---|---|
| `Microsoft.Dynamics.Nav.EditorServices.Host.dll` | Language server **and** debug adapter (same binary, different arguments) |
| `alc.dll` | Compiler |
| `altool.dll` | CLI: workspace compile, publish, tests, auth, package inspection |
| `Microsoft.Dynamics.Nav.{CodeCop,UICop,PerTenantExtensionCop,AppSourceCop}.dll` | Built-in analyzers |

Since AL 18 these are framework-dependent .NET assemblies (`*.runtimeconfig.json`
asks for `Microsoft.NETCore.App` **and** `Microsoft.AspNetCore.App` 10.0). They
are identical on every OS and are started as `dotnet <file>.dll`. Older
extensions (≤ 18.0.2293710) shipped native per-platform hosts under
`bin/<platform>/`; nvim-al does not support that layout.

The NuGet tool `Microsoft.Dynamics.BusinessCentral.Development.Tools` (command
`al`) ships `altool`, `alc` and the cops, but **not** EditorServices.Host. Its own
language server (`altool launchlspserver`) is a different, standard-LSP server:
it reads `.code-workspace` files itself and supports hover, definition,
references, rename and formatting, but it registers **no diagnostics** (neither
push nor pull) and **no code actions**. It is not a replacement for
EditorServices in an editor.

## 2. Language server

### 2.1 Start

```
dotnet <bin>/Microsoft.Dynamics.Nav.EditorServices.Host.dll /sessionId:<any-id> [options]
```

stdio, JSON-RPC with `Content-Length` framing. Options use the
`/name:value` syntax. VS Code derives them from settings:

| Option | From |
|---|---|
| `/disableTelemetry` | telemetry off |
| `/telemetryLevel:<v>` | `telemetry.telemetryLevel` |
| `/env:<v>`, `/browser:<v>`, `/incognito:<v>` | `al.env`, `al.browser`, `al.incognito` |
| `/logLevel:<v>` | `al.editorServicesLogLevel` (`Debug`/`Verbose`/`Normal`/`Warning`/`Error`) |
| `/inlayHintsParameterNames:<b>`, `/inlayHintsFunctionReturnTypes:<b>` | `al.inlayhints.*.enabled` |
| `/semanticFolding:<b>` | `al.semanticFolding.enabled` |
| `/extendGoToSymbolInWorkspace:<b>`, `…ResultLimit:<n>`, `…IncludeSymbolFiles:<b>` | `al.extendGoToSymbolInWorkspace.*` |
| `/testCoverageCachePath:<p>` | `al.testCoverageCachePath` |
| `/delayAfterLastDocumentChange:<ms>`, `/delayAfterLastProjectChange:<ms>` | `al.compilationOptions` |
| `/waitForDebugger` | `al.debug` |

Logs are written next to the host binary (`EditorServices.log`). In a
read-only install that fails silently, which is harmless.

### 2.2 Capabilities (from `initialize`)

`textDocumentSync: 2` (incremental), hover, references, document highlight,
document symbols, workspace symbols, code actions, formatting, range
formatting, rename, implementation, type hierarchy, completion, signature
help. **`definitionProvider: false`**: see 2.6.

**Completion item labels are objects**, not strings (verified on 30.0):
`"label": { "label": "\"No.\" (PK1)", "description": "" }`. This breaks the
LSP spec and every completion engine. A client has to replace `label` with
`label.label` before passing items on. nvim-al does this by wrapping the client's
`request` method, so built-in completion, nvim-cmp and blink all receive
strings.

### 2.3 Workspace model

The server does not read `.code-workspace` files. The client owns the model:

- a list of **workspace folders**, each `{ uri, name, index }`;
- per folder, its `app.json`;
- one **active** folder at a time.

`initialize` gets `rootUri`/`rootPath` (VS Code: the first folder) and
`workspaceFolders`.

### 2.4 Startup and project switch sequence

1. `initialize` → `initialized`.
2. For each folder with an `app.json`: request
   `al/loadManifest { projectFolder: <fs path>, manifest: <app.json text> }` →
   `{ success, manifest }` (the server's normalized manifest).
3. Compute the **closure** of the active folder (2.5).
4. Request `al/setActiveWorkspace { currentWorkspaceFolderPath: <folder object>, settings: <WorkspaceSettings> }`
   → `{ success: true }`.
5. For each folder in the closure other than the active one, notify
   `workspace/didChangeConfiguration { settings: <WorkspaceSettings for that folder> }` with
   `setActiveWorkspace: false` and `dependencyParentWorkspacePath: <active folder path>`.
   VS Code sends this once per (dependency, parent) pair.

The payload **must** be wrapped as `{ currentWorkspaceFolderPath, settings }`.
With the settings fields at the top level the request fails without an
error message and the project never loads.

Re-send step 4 (and 5) whenever the active *folder* changes, i.e. when the
user moves to a buffer in another project. VS Code guards on the last folder
path and does nothing when the folder stays the same. Measured: a switch takes
about 0.1 s once the closure is loaded. It does not re-index from scratch.

`WorkspaceSettings`:

```jsonc
{
  "workspacePath": "<folder fs path>",
  "alResourceConfigurationSettings": {
    "assemblyProbingPaths": [],          // must be an array, never null
    "codeAnalyzers": ["${CodeCop}", "..."],
    "enableCodeAnalysis": true,
    "backgroundCodeAnalysis": "Project", // "None" | "File" | "Project"; VS Code maps true→"File", false→"None"
    "packageCachePaths": ["..."],        // al.packageCachePath, string promoted to array
    "ruleSetPath": "...",
    "enableCodeActions": true,
    "incrementalBuild": false,
    "enableCodeLensExternalUsage": false,
    "outputAnalyzerStatistics": false,
    "enableExternalRulesets": true,
    "namespaceTemplate": null,
    // optional, from al.compilationOptions:
    "generateReportLayout": false, "parallelBuild": true,
    "maxDegreeOfParallelism": 2, "captureSymbolUsage": false, "outFolder": "..."
  },
  "setActiveWorkspace": true,
  "dependencyParentWorkspacePath": null,
  "expectedProjectReferenceDefinitions": [ { "appId", "name", "publisher", "version" } ],
  "activeWorkspaceClosure": [ "<fs path>", "..." ]
}
```

Settings are read **per folder** with VS Code's precedence: defaults → user
settings → `.code-workspace` `settings` → the folder's `.vscode/settings.json`.
Variables such as `${workspaceFolder}`, `${CodeCop}` and `${analyzerFolder}`
are passed through unresolved and expanded by the server. `${analyzerFolder}`
is the server's own `bin/Analyzers/` directory (flat `bin/` in the dotnet
layout). If that directory is read-only, third-party analyzers placed "next to
the cops" have to be given as absolute paths instead.

`assemblyProbingPaths: null` crashes the server. The VS Code default
`./.netpackages` is fine locally but has been reported to hang on network
mounts.

### 2.5 Closure and project references

The client computes this, not the server:

- **Project references** of folder F: every *other* workspace folder whose
  `app.json` identity (`id`, `name`, `publisher`, `version`) matches a
  dependency in F's `app.json`.
- **Closure** of F: F plus the transitive project references, found
  depth-first, each folder visited once.
- `expectedProjectReferenceDefinitions` = identities of F's *direct* project
  references.
- `activeWorkspaceClosure` = the closure paths, sent only for the active folder.

Dependencies that are not workspace folders (Microsoft apps, third-party apps)
come from `.app` symbol files in the package cache.

Verified against a real repository: test app active, app under test in the
closure, its compiled `.app` removed from the package cache. Hover and
go-to-definition into the app's *source* worked, and diagnostics arrived for
both projects.

`al/hasProjectClosureLoadedRequest { workspacePath: <lowercased fs path> }` →
`{ loaded }` reports whether the server has loaded a closure.

### 2.6 Go to definition

`textDocument/definition` returns null. Use

```
al/gotodefinition {
  browserInfo: { browser, incognito }, environmentInfo: { env },
  textDocumentPositionParams: { textDocument: { uri }, position }
}
→ { uri, range } | null
```

`uri` is either `file://…` or `al-preview://…` (an object inside a symbol
package). Fetch preview content with `al/previewDocument { Uri: <uri> }` →
`{ content }` (CRLF line endings) and show it read-only. Symbol-package
objects come back as `al-preview://allang/<package>/<Type>/<id>/<Name>.dal`;
a `file://…/<Name>.dal` result needs its last path segment joined back onto
the parsed parent URI. Verified: a jump to `Record Customer` returns
`al-preview://allang/app/Table/18/Customer.dal`, about 5,000 lines of source.

### 2.7 Diagnostics

Standard push: `textDocument/publishDiagnostics`. With
`backgroundCodeAnalysis: "Project"` the server analyses and publishes every
file of the active project, not just open buffers. Measured: first
diagnostics 2.7 s after `setActiveWorkspace`, 352 diagnostics in 47 files
for a mid-sized app, covering the compiler, CodeCop, UICop,
PerTenantExtensionCop and six third-party ALCops analyzers, with the ruleset
applied. When a folder is removed, its diagnostics should be cleared on the
client side.

### 2.8 Code actions

`textDocument/codeAction` returns actions with a **command**, not an edit:

```
{ title, kind: "quickfix", command: { command: "al/runCodeAction",
  arguments: [ { fileName, selection, identifier, wantsTextChanges: true } ] } }
```

Running it via `workspace/executeCommand` makes the server send a standard
`workspace/applyEdit` request with the text edits, then answer the command
with `null`. Any LSP client that implements `applyEdit` handles this.
Observed actions include suppressing a diagnostic (`#pragma warning disable`,
for this instance, the document or the project), real fixes such as
AA0248 "Add this" and AC0031 "Convert to case", and none at all for many
third-party analyzer rules.

### 2.9 Other server→client traffic

| Method | Kind | Client must |
|---|---|---|
| `al/activeProjectLoaded` | **request** | respond (`null`). Some versions never send it |
| `al/progressNotification` | notification | optional: progress UI |
| `al/projectsLoadedNotification` | notification | optional |
| `al/refreshExplorerObjects`, `al/updateTests` | notification | ignore |
| `al/symbolsMissing`, `al/manifestMissing` | notification | tell the user |
| `window/logMessage`, `window/showMessage` | standard | |

Unknown server→client requests must still get a response, or the server
waits.

### 2.10 Client→server requests used by commands

| Request | Purpose | Payload (summary) |
|---|---|---|
| `al/createPackage` | build the active project | `{ projectDir, args: ['-project:"<dir>"', …compiler options], isRad, vSCodeExtensionVersion, forceBuildDependencies }` → `{ success }`; errors arrive as diagnostics |
| `al/downloadSymbols` | fetch symbols from a server | `{ configuration: <launch config>, … }` |
| `al/checkSymbols` | are symbols present | |
| `al/symbolSearch` | workspace symbol search | |
| `al/getPackageDependencies` | dependency list | |
| `al/getEventPublishersRequest` | event publishers | |
| `al/generatePermissionSet…` | permission set generation | |
| `al/saveUsernamePassword` | cache credentials (server's own cache) | `{ configuration, credentials: { username, password } }` |
| `al/checkAuthenticated` | | `{ configuration, … }` → `{ authenticated }` |
| `al/didChangeWorkspaceFolders` | folder added/removed | `{ added: [folder], removed: [folder] }` |
| `al/didChangeActiveDocument` | active editor changed | `{ textDocument: { uri }, sequenceNumber }` |

Server-connection requests are wrapped as `{ configuration: <launch config>, …params }`.
On an `Unauthorized` error with `UserPassword` authentication, VS Code prompts
for credentials, sends `al/saveUsernamePassword` and retries.

## 3. Debug adapter

### 3.1 Start

```
dotnet <bin>/Microsoft.Dynamics.Nav.EditorServices.Host.dll /startDebugging [language server options] /projectRoot:<folder>
```

stdio, DAP. **Start it with the project folder as working directory.** Without
`al.packageCachePath`, the adapter uses its working directory as the package
cache root and scans it recursively. From `$HOME` that takes a long time or
never finishes (symlink loops), and the call stack never loads.

`initialize` capabilities: configurationDone, conditional breakpoints,
evaluate for hovers, completions, restart, terminate, delayed stack trace
loading. No function breakpoints, no set-variable, no step-back.

### 3.2 Configurations

`request` is `launch`, `attach` or `snapshotInitialize`. VS Code passes the
user's launch configuration through a resolver before sending it. What the
resolver does:

- default `port` (7049 for launch/attach) and `mcpServerPort`;
- `breakOnError` / `breakOnRecordWrite`: booleans are sent as is, string values
  go into `breakOnErrorBehaviour` / `breakOnRecordWriteBehaviour` (sending both
  logs a deprecation note);
- attach: `breakOnNext` defaults to `WebServiceClient`, `"Agent"` maps to
  `ClientService`, `sessionId` defaults to `-1`;
- launch: adds `projectReferenceDefinitions` (as in 2.5), `publishOnly`,
  `isRad`, `justDebug`;
- `usePublicURLFromServer` and `validateServerCertificate` default to `true`;
- `useInteractiveLogin`, `entraIdAuthentication` come from settings;
- `useMcpServerForDebugging` defaults to `true` (set it to `false` to avoid
  the MCP side channel);
- sets `isResolved: true`.

`snapshotInitialize` nests the connection fields under `configuration`.

### 3.3 Credentials

For `UserPassword` the adapter takes, in order: the environment variables
`BC_SERVER_USERNAME` / `BC_SERVER_PASSWORD`, then its own encrypted cache file
next to the host binary (filled by the language server's
`al/saveUsernamePassword`). An editor can prompt once and pass the credentials
through the adapter's environment, so no cache file is needed.

### 3.4 Session lifecycle

1. `initialize` → `attach`/`launch` (response: success, empty body).
2. The adapter sends `initialized` **when a debuggee session attaches**, not
   right after the response, and sometimes twice (a web-client sign-in creates
   two sessions). Re-send `setBreakpoints` and `configurationDone` on **every**
   `initialized`.
3. Breakpoints come back `verified: true` once bound.
4. `stopped` → `stackTrace` (frames carry real file paths) → `scopes`
   (`Globals`, `Locals`, `Database Statistics`) → `variables` → `evaluate`.
   `next`/`stepIn`/`stepOut`/`continue` work as usual.
5. `terminated` when the debugged session ends.

With `breakOnNext` the adapter attaches to the *next* session of that client
type that starts *after* the attach is armed. A session that starts earlier is
missed. Verified: attach with `breakOnNext: WebServiceClient`, API call, stop
in an API page trigger with `Rec` populated, evaluate, step, continue.

Only one adapter per environment: every adapter holds its own debugger hub
connection, and an older armed one takes the next break. Kill adapters on
exit.

Custom events beyond DAP, which a client should handle:

| Event | Body | Client action |
|---|---|---|
| `al/openUri` (`AlOpenUriEvent`) | `{ uri }` | open in browser |
| `al/deviceLogin` (`AlDeviceLoginEvent`) | `{ message, token, uri }` | show the device code and open the URI |
| `window/logMessage` | | log |
| `al/refreshExplorerObjects` | | ignore |

During a debug session VS Code also resolves `al-preview://` documents
through the debug session (`customRequest("al/previewDocument", { Uri })`)
instead of the language server.

## 4. altool (command line)

From `altool.dll` (in the vsix `bin/` or the NuGet tool). Relevant commands:

| Command | Notes |
|---|---|
| `workspace compile <file>.code-workspace` | compiles all folders in dependency order. `--packagecachepath`, `--outfolder`, `--logdirectory`, `--errorlogdirectory` (a structured JSON error log per project), `--ruleset`, `--analyzers CodeCop,UICop,PTECop,AppSourceCop`, `--customanalyzers <paths>` (accepts `${AnalyzerFolder}`), `--maxcpucount` |
| `compile <alc args>` | one project; forwards to alc (`/project:`, `/packagecachepath:`, `/analyzer:`, `/ruleset:`, `/out:`) |
| `publishapp [<app>] --project <dir>` | reads `.vscode/launch.json` from the project for connection settings; `--schemaupdatemode`, `--server`/`--port`/`--serverinstance`/`--tenant`/`--authentication`; UserPassword from `BC_SERVER_USERNAME`/`BC_SERVER_PASSWORD` |
| `runtests <codeunitId> --project <dir>` | `--testmethods`, `--testgroups <json>`, structured JSON output |
| `downloadsymbols --project <dir>` | in the vsix-bundled altool 30.0.43 and the NuGet 30.x tool, not in NuGet 18.1. Same connection flags as `publishapp`, or `--globalsourcesonly` (NuGet feeds, no server); `--force`, `--raw` |
| `auth login` / `auth logout` | Entra ID token cache |

The workspace file's `al.*` settings are **not** applied by
`workspace compile`. Analyzers and the ruleset have to be passed explicitly.

## 5. Verified probes

| Probe | Result |
|---|---|
| EditorServices, one project, VS Code payload | diagnostics in 2.7 s, all analyzers loaded, ruleset applied |
| Closure, test → app from source | hover and definition into app source, diagnostics for both, 0.1 s project switch |
| Code action → `executeCommand` → `applyEdit` | correct `#pragma` edits received |
| DAP attach + breakpoint + stack + variables + evaluate + step | works against BC 28.3 on Linux, credentials from environment |
| altool LSP (`launchlspserver --workspacefile`) | loads 47 projects, hover and definition work, **no diagnostics** |
