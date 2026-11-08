# LLVM Dev Workbench

A native macOS workspace for LLVM development, with a CLI backed by the same Rust
Core. Open an LLVM monorepo, choose projects/backends/runtimes, prepare independent
build environments, discover actual outputs, and build/run/test selected targets.
Built through **vibe coding**, with a **Claude-inspired UI**: warm neutral
surfaces, restrained terracotta accents, and a quiet workspace layout. The native
app supports **macOS 14+ on Apple Silicon**; its interface is currently in Chinese.
This is an independent project, unaffiliated with LLVM or Anthropic.

## Try the app

Prerequisites: Rust/Cargo, Xcode Command Line Tools (including Swift and a C/C++
compiler), CMake, Ninja, and Python 3 for LLVM's test tools. Your LLVM checkout
may require newer tool versions or additional dependencies. Install prerequisites
before building; Workbench does not install them automatically.

```sh
git clone git@github.com:xiongzile/llvm-dev-workbench.git
cd llvm-dev-workbench
scripts/build-macos.sh
open "dist/LLVM Workbench.app"
```

The script builds the shared Core and SwiftUI app, then creates a locally
ad-hoc-signed app bundle. The app is not notarized. This project uses a build
script; an Xcode project is not required.

1. Open the LLVM source directory (the parent of `llvm/`, `clang/`, and `runtimes/`).
2. Choose a saved environment, or choose **新建环境**. Existing build directories are not auto-imported.
3. Select projects, backends, and runtimes. These lists come from that checkout.
4. Save and prepare the environment. This runs CMake; it does not build all LLVM.
5. Select an actual target, such as `clang`, `llc`, `opt`, or a library, and build it.
6. Use **运行…** for executable arguments, **测试** for regression tests, or
   **在 Finder 中显示** to locate an output. Running first updates the target.

The editor supports compiler paths and compile concurrency. New builds default to
8 compile jobs, 1 link job, 2 TableGen jobs, assertions, and optimized TableGen.
Lower compile concurrency on memory-constrained machines. Modes are
RelWithDebInfo (daily), Debug (debugging), and Release (fast validation).

## Shared Core, two thin frontends

```text
Rust CLI ─────────────────────┐
                             ├── Rust Core ── CMake / Ninja / lit / built tools
SwiftUI app ── in-process ABI ┘
```

The app links `libllvm_dev_core.dylib` directly. It never runs the CLI. A small C
ABI carries structured domain requests/results into Swift Codable models. Core
owns settings, validation, build plans, target discovery, process groups,
cancellation, locks, and persisted history. Swift owns UI and native file/IDE
integration; the CLI owns terminal arguments and output.

| Source | Responsibility |
|---|---|
| `crates/llvm-dev-core` | Shared domain and execution engine |
| `crates/llvm-dev-cli` | Native CLI frontend |
| `apps/macos` | SwiftUI app, typed bridge, and C ABI header |
| `scripts` | App packaging, icon generation, and native checks |
| `tests/macos` | Swift model and Core integration tests |
| `docs` | Architecture and validation guide |

Generated `target/`, `build/`, and `dist/` directories are ignored by Git and can
be recreated. They hold this application's build outputs, separate from the LLVM
build directories it manages. See [architecture](docs/architecture.md).

## Native CLI

Build with `cargo build --release --workspace`. The root `./llvm-dev` launcher
executes `target/release/llvm-dev`; it contains no build policy.

```sh
./llvm-dev --source /path/to/llvm-project inspect
./llvm-dev --source /path/to/llvm-project catalog
./llvm-dev --source /path/to/llvm-project init --name Daily --projects clang,lld --backends Native
./llvm-dev --source /path/to/llvm-project --profile Daily configure
./llvm-dev --source /path/to/llvm-project --profile Daily targets
./llvm-dev --source /path/to/llvm-project --profile Daily build clang llc
./llvm-dev --source /path/to/llvm-project --profile Daily run clang -- --version
./llvm-dev --source /path/to/llvm-project --profile Daily edit --backends Native,RISCV
./llvm-dev --source /path/to/llvm-project --profile Daily configure
./llvm-dev --source /path/to/llvm-project --profile Daily clone --name Debug --mode debug
./llvm-dev --source /path/to/llvm-project --profile Daily test llvm/test/path/to/test.ll --dry-run
```

Lists accept commas or semicolons. `--json` returns structured output;
`--dry-run` on configure/build/run/test returns the exact Core plan without
starting processes. A build requires explicit targets. Ctrl-C cancels the CLI's
owned process group. `run ... -- --help` passes help through to the built tool.

`init` creates a profile. `edit` changes a saved profile. `clone` creates a
separate build tree from a saved profile. After
changing projects/backends/runtimes or concurrency, prepare the environment
again. Changing mode/compiler in an already-configured environment requires a
copy, preserving the earlier incremental build.

## Environment definitions and disposable build outputs

Workbench only lists environments explicitly saved through its UI or CLI. It
never scans `build/`, `llvm/build/`, or `cmake-build*` to create environments.
Opening a checkout for the first time shows an empty environment list.

Environment definitions, app settings, logs, history, and locks live under
`~/Library/Application Support/LLVMWorkbench` on macOS and
`$XDG_STATE_HOME/llvm-workbench` (default `~/.local/state/llvm-workbench`) elsewhere.
`LLVM_WORKBENCH_HOME` overrides this application-state root.

Build outputs live under `<llvm-checkout>/build/<environment-name>/`. A safe,
readable directory name is derived from the environment name. Existing files,
symlinks, and paths reserved by another environment are not reused; a numeric
suffix resolves collisions. Renaming a saved environment does not move its build.
The editor previews the build directory; the environments page shows both the
configuration file and build directory.

Deleting an environment's build directory, or the checkout's entire `build/`,
does not delete its definition. Reopen/refresh the workspace, choose **准备环境**,
and build again. CMake regenerates its cache, Ninja rules, and target metadata
using the saved projects, backends, runtimes, compiler paths, and build mode.
CMake cache files inside `build/` are disposable generated state, not the source
of truth for Workbench environments.

On opening a workspace with profiles from 0.2.0/0.2.1, builds that used the old
application-state `builds/` location are assigned checkout-local directories.
Profile IDs/settings are retained and the previous definitions are backed up
under `backups/` in application state. Absolute-path CMake caches are not copied
or moved; prepare the new directory before building. Old outputs are retained.
A running old build keeps its location until a later workspace refresh.

Source files, unrelated build directories, CMake presets, CLion settings, and
Git configuration are preserved.

Target types and output paths come from CMake File API. A read-only Ninja
fallback can list build targets when metadata is absent, but cannot reliably
classify executable outputs; prepare the saved environment for full discovery.
“已生成” means the output exists; it does not claim the output is current.
Running always builds first and never substitutes a system compiler/tool.

CLI and app share OS locks per build directory. Conflicting operations
or edits are rejected. Cancellation sends signals to the owned process group,
reaps it, and releases the lock before publishing completion. Unrelated builds
started outside this tool do not participate in its lock protocol.

## Tests and runtimes

Core routes selected LLVM, Clang, LLD, MLIR, and bootstrap libc++ regression test
paths to their dependency targets and `llvm-lit`. Other suites can be built/run
through their discovered `check-*` targets. Architecture-specific LLVM CodeGen/MC
tests are rejected when their backend is disabled.

libc++ selection adds Clang, libc++abi, and libunwind for the bootstrap runtime
workflow. Runtime tests use the generated runtime test tree. All other projects
and backends are general selectable components, not hardcoded development tracks.

## Current boundaries

- Single-configuration Ninja monorepo builds; macOS app currently arm64 only.
- External prerequisites and project-specific optional dependencies are detected
  or reported by CMake, not installed automatically.
- Source opening in a chosen IDE is supported; embedded debugging, IDE preset
  synchronization, cross toolchains/sysroots, and standalone runtimes are not.
- Individual outputs and paths are available; redistributable LLVM toolchain
  packaging is not implemented. A usable Clang distribution needs more than its
  binary (resource headers and runtime libraries, for example).
- Linux support is in the Core/CLI design, but this preview was tested on macOS.
- License choice, universal builds, and notarization remain future work.

Validation scope and manual checks: see [testing](docs/testing.md).
Run the automated checks with:

```sh
cargo test --workspace -- --test-threads=1
scripts/build-macos.sh
scripts/test-macos.sh
```
