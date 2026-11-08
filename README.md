# LLVM Dev Workbench

A macOS app for working on LLVM without remembering a long list of CMake and
build commands. Choose the components you need, build a tool, and run its tests
from one window.

Built through **vibe coding**, with a **Claude-inspired UI**. Supports **macOS 14+
on Apple Silicon**. The app supports English and Simplified Chinese. This is an
independent project, unaffiliated with LLVM or Anthropic.

## Install and open

You need Rust/Cargo, Xcode Command Line Tools, CMake, Ninja, and Python 3 installed.
You also need an LLVM source checkout. Your chosen LLVM version may have
additional requirements.

Build the app from source:

```sh
git clone git@github.com:xiongzile/llvm-dev-workbench.git
cd llvm-dev-workbench
scripts/build-macos.sh
open "dist/LLVM Workbench.app"
```

You can then copy `dist/LLVM Workbench.app` into your Applications folder and
launch it normally. The current app is locally signed and is not notarized.

## Choose your language

The app follows your macOS language preferences by default. Use **Language** at
the bottom of the sidebar, or the **Language** menu, to choose **Follow System**,
**English**, or **Simplified Chinese**. The change takes effect immediately and
is remembered next time you open the app. Your environments and build settings
stay the same. Compiler output is shown in its original language.

This guide uses the English interface labels.

## Your first build

1. Open the app and select your LLVM checkout: the directory containing `llvm/`,
   `clang/`, and `runtimes/`, rather than the `llvm/` subdirectory.
2. Click **New Environment** and give it a name, such as `Daily`. An environment is a
   saved set of component choices and build settings, with its own build directory.
3. For a first Clang build, select the `clang` project, the `Native` backend, and
   the daily development mode. Leave runtimes empty unless you need them.
4. Save with **Prepare after saving** enabled, or click **Prepare Environment** afterwards. Wait for
   preparation to finish; this configures the build without compiling all LLVM.
5. Find `clang` in the target list, select it, and click **Build clang**.
6. When the build finishes, click **Run…**, enter `--version`, and click
   **Build & Run**. The output appears in the task log.

The first build can take a while. Subsequent builds reuse that environment's
outputs. The bottom task area shows progress and logs; you can cancel a running
operation there.

## Choose what to work on

The environment editor lists the components available in your LLVM checkout.

| Choice | What to select |
|---|---|
| Projects | Additional tools and projects, such as `clang`, `lld`, or `mlir`. LLVM's own tools are available without selecting an additional project. |
| Backends | The architectures you need to generate or test code for. `Native` selects your host architecture; add others when your work needs them. |
| Runtimes | Libraries such as `libcxx` or `compiler-rt`, when those are part of your work. Selecting `libcxx` also adds its required compiler and companion runtimes. |
| Build mode | Daily development keeps debug symbols and assertions. Debug is useful for stepping through code; Release is available for optimized builds. |
| Compiler and concurrency | Choose compiler paths when needed. Lower compile concurrency if builds use too much memory. |

To change the components later, edit the environment and prepare it again. To
try a different compiler or build mode after configuration, use **Duplicate…** to
create a separate environment. Switch environments in the sidebar.

Existing build directories are not imported automatically. Create an environment
explicitly even if you have previously built LLVM by hand.

## Build and run tools

Open **Artifacts**, search for a target, and select it. The list reflects the current
environment, so enable the relevant project or backend if something is missing.

- Click **Build** to build the selected target and its dependencies.
- Click **Run…** to run an executable. Enter **one argument per line**; a path
  containing spaces stays on one line. Workbench updates the build before running.
- Use **Show in Finder** to locate a generated output.
- **Built** means the output exists. After changing source code, build or run it
  again to update it.

You can select tools such as `clang`, `llc`, `opt`, and `llvm-mc`, as well as
libraries and test targets. Workbench builds individual targets; it does not yet
package a complete LLVM toolchain for distribution.

## Run tests

1. Open **Tests**.
2. Click **Choose…** and choose a regression test file or directory inside your
   LLVM checkout.
3. Click **Run Tests** and inspect the result in the logs.

Selected-test support covers LLVM, Clang, LLD, MLIR, and bootstrap libc++ tests.
For a whole suite, select an available `check-*` target, such as `check-llvm`,
and build it. Architecture-specific tests need the corresponding backend enabled.

## Find outputs and clean up

Your LLVM build outputs are stored under:

```text
<llvm-checkout>/build/<environment-name>/
```

The **Environments** page shows the exact path. If a directory already exists, Workbench
chooses another name instead of overwriting it.

To reclaim space, wait for the build to stop and delete that environment's build
directory. Its saved settings remain in
`~/Library/Application Support/LLVMWorkbench/`. Reopen or refresh the workspace,
select the environment, and click **Prepare Environment** to build again.

## Optional: use the CLI

The app build also creates the `llvm-dev` command. For the CLI alone, run
`cargo build --release --workspace`. From this repository, try:

```sh
./llvm-dev --source /path/to/llvm-project init --name Daily --projects clang --backends Native
./llvm-dev --source /path/to/llvm-project --profile Daily configure
./llvm-dev --source /path/to/llvm-project --profile Daily targets
./llvm-dev --source /path/to/llvm-project --profile Daily build clang llc
./llvm-dev --source /path/to/llvm-project --profile Daily run clang -- --version
```

Use `./llvm-dev --help` for more commands. Add `--dry-run` to configure, build,
run, or test commands to preview what will execute. Press Ctrl-C to cancel.
Environments saved in the app are also available in the CLI.
