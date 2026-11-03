# Debugging checklist

Run against a real Business Central environment before each release. Debugging
can't be unit-tested end to end: it needs a service tier, a published app and a
session to attach to.

## Setup

- An AL project whose app (with the code you'll break in) is published to the environment.
- A launch configuration for it: `.vscode/launch.json`, the workspace file's
  `launch` section, or the `launch` hook. UserPassword credentials either in
  `BC_SERVER_USERNAME`/`BC_SERVER_PASSWORD` or entered at the prompt.
- nvim-dap installed. No other AL debug adapter running for the same
  environment (`pgrep -af startDebugging` shows nothing).

## Attach

1. Open a source file of the project and set a breakpoint in code a web service
   call runs (e.g. `OnAfterGetRecord` of an API page): `:lua require("dap").toggle_breakpoint()`.
2. `:AL debug` and pick an `attach` configuration with `breakOnNext: WebServiceClient`.
3. Wait until the adapter says *Debugger will attach to the next session of type
   WebServiceClient*. Sessions that start before that are missed.
4. Trigger the call (e.g. `curl` the API).
5. Check:
   - [ ] execution stops at the breakpoint line
   - [ ] the call stack shows the trigger with the real file path
   - [ ] Globals list `Rec` with the expected value
   - [ ] hover / `require("dap.ui.widgets").hover()` evaluates `Rec."No."`
   - [ ] step over moves to the next line
   - [ ] continue lets the call finish (HTTP 200)
6. `:lua require("dap").terminate()` and check that no `startDebugging` process remains.

## Launch (publish and debug)

1. Change something visible in the app, e.g. a message text.
2. `:AL debug` and pick a `launch` configuration. Modified project buffers are saved first.
3. Check:
   - [ ] the adapter publishes the app (output: publishing, success)
   - [ ] with `launchBrowser: true` the web client opens (`al/openUri`)
   - [ ] a breakpoint in code reached from the start page stops

## Results

| Date | Extension | BC | Attach | Launch | Notes |
|---|---|---|---|---|---|
| 2026-11-03 | 30.0.2863738 | 28.3 (Docker) | ✅ all checks | not run | nvim-dap 0.10+, API page `TransferOrderEntity`, `Rec = '1002'`, step 193→194 |
