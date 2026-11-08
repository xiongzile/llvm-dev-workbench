# Architecture

LLVM Dev Workbench has one shared Rust Core and two thin frontends:

```text
Rust CLI ─────────────────────┐
                             ├── Rust Core ── CMake / Ninja / lit / built tools
SwiftUI app ── in-process ABI ┘
```

The app directly links the bundled `libllvm_dev_core.dylib`. It does not execute
the CLI. `apps/macos/Bridge/LLVMWorkbenchCore.h` exposes a small C ABI carrying
JSON requests and responses. Swift decodes responses into typed models. Callers
release returned strings with `llvmwb_free`.

## Responsibilities

Core owns checkout component discovery, environment validation and persistence,
CMake plans, File API output discovery, test routing, process execution,
cancellation, locks, logs, and history. The CLI handles terminal arguments and
output. SwiftUI handles presentation, file pickers, Finder/IDE integration, and
selection state.

Both frontends use the same persisted definitions and per-build OS locks. Build
operations execute asynchronously. Cancellation terminates the operation's owned
process group, waits for termination, and releases its lock before completion.
Builds started outside Workbench do not participate in this lock protocol.

## Storage

Application state lives outside the LLVM checkout:

- macOS: `~/Library/Application Support/LLVMWorkbench/`
- Other platforms: `$XDG_STATE_HOME/llvm-workbench/`, defaulting to
  `~/.local/state/llvm-workbench/`
- Override: `LLVM_WORKBENCH_HOME`

Disposable build outputs live in `<llvm-checkout>/build/<environment-name>/`.
Existing paths are preserved and receive a collision suffix when necessary.
Deleting build outputs does not delete environment definitions. Preparing the
environment regenerates the CMake cache and build rules.

Environments are created explicitly. Opening a checkout does not scan or import
existing build directories. Component discovery reads the selected checkout's
available projects, backends, and runtimes; it does not assume a fixed LLVM
development area. libc++ has additional bootstrap dependencies and test routing.

## Interaction

Preparing an environment runs CMake only; building requires explicit targets.
The UI publishes its starting state synchronously, before awaiting Core, so
buttons disable immediately and repeat clicks cannot create another operation.
Cancellation requested during startup is retained until Core returns a job ID.

Target/output information comes from CMake File API, with limited read-only
Ninja target discovery when metadata is missing. An existing output is not
necessarily up to date; running a tool always performs an incremental build
first. Configured environments require a separate build tree when changing
compiler or build mode.

## Visual direction

The native SwiftUI/AppKit interface takes inspiration from Claude's visual
style: ivory surfaces, charcoal text, serif headings, terracotta accents, and
quiet separators. The app icon is drawn locally by `scripts/make-icon.swift`.
