# LLVM Dev Workbench

A macOS app for working on LLVM without remembering a long list of CMake and
build commands. Choose the components you need, build a tool, and run its tests
from one window.

Built through **vibe coding**, with a **Claude-inspired UI**. Supports **macOS 14+
on Apple Silicon**. The app supports English and Simplified Chinese. This is an
independent project, unaffiliated with LLVM or Anthropic.

## Install and open

1. Download **[LLVM Workbench for macOS](https://github.com/xiongzile/llvm-dev-workbench/releases/latest)**
   and choose the `macos-arm64.zip` asset. Requires an Apple Silicon Mac with macOS 14 or later.
2. Unzip it and drag **LLVM Workbench.app** into your Applications folder.
3. Open the app and select your LLVM source checkout.

The download includes the app; you do not need Rust or Cargo to use it. To build
LLVM projects, install Xcode Command Line Tools, CMake, Ninja, and Python 3.
Your chosen LLVM version or components may have additional requirements.

This preview is not Developer ID signed or notarized. If macOS blocks it on first
launch, review [Apple's guidance on opening downloaded apps](https://support.apple.com/en-us/102445).
If you trust this download, use **System Settings → Privacy & Security → Open Anyway**.
The release also includes a SHA-256 checksum file for verifying the download.

### Build the app from source (optional)

For contributors, install Rust/Cargo as well, then run:

```sh
git clone git@github.com:xiongzile/llvm-dev-workbench.git
cd llvm-dev-workbench
scripts/build-macos.sh
open "dist/LLVM Workbench.app"
```

The resulting app is at `dist/LLVM Workbench.app`.

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
| Linker | Choose **LLD** for linking with an installed LLD, **System default** to use the compiler's default, or **Custom path…** for a specific linker executable. |
| Compiler and concurrency | Choose compiler paths when needed. Lower compile concurrency if builds use too much memory. |

To change the components later, edit the environment and prepare it again. To
try a different compiler or build mode after configuration, use **Duplicate…** to
create a separate environment. Switch environments in the sidebar.

Existing build directories are not imported automatically. Create an environment
explicitly even if you have previously built LLVM by hand.

### Use LLD for linking

Install LLD first (on macOS, `brew install lld`), then choose **Linker → LLD** in
the environment editor and save with **Prepare after saving** enabled. Workbench
looks beside the selected compiler, on PATH, and in standard Homebrew locations.
On macOS it uses the Mach-O driver, `ld64.lld`; on Linux it uses `ld.lld`.
You can also select its absolute executable path (without spaces). The selected compiler must support
LLVM's `-fuse-ld` option.

Selecting `lld` in **Projects** builds the linker as an output; it does not select
the linker used to build LLVM. Switching linkers requires preparing the environment
again and can relink existing targets. Selecting **System default** clears the
previous LLD selection. Build outputs are kept.

From the CLI:

```bash
./llvm-dev --source /path/to/llvm-project --profile Daily edit --linker lld
./llvm-dev --source /path/to/llvm-project --profile Daily configure
# To switch back:
./llvm-dev --source /path/to/llvm-project --profile Daily edit --linker system
./llvm-dev --source /path/to/llvm-project --profile Daily configure
```

## Build and run tools

Open **Workbench**, search for a target, and select it. The list reflects the current
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

Drag the gaps beside the sidebar or target details to resize them. Workbench remembers
these widths. Star a target to favorite it, then use the star above the list to show
favorites. The details panel shows recent tasks and their logs for the selected target.
Use **⌘F** to search, **⌘B** to build, and **⌘R** to open run arguments.

## Open in CLion or VS Code

1. Install **CLion** or **Visual Studio Code**. For VS Code, install LLVM with
   `clangd` too (`brew install llvm` on macOS).
2. Select your environment and, optionally, a tool such as `clang`, `llc` or `opt`.
3. Click **Open in IDE…**, choose your editor, and click **Prepare & Open**.
   Workbench prepares an unconfigured or changed environment first, then builds
   the available LLVM, Clang, MLIR and Flang generated-header targets. The first
   open may take a few minutes to build TableGen and its dependencies; subsequent
   opens update them incrementally. This also restores deleted generated headers
   without disabling precompiled headers. CLion may ask you to trust this local project and
   confirm its first-open settings; the generated values are already filled in.
4. In CLion, use the enabled **Workbench** CMake profile. Choose a target to build,
   or the **Workbench: <tool>** run configuration to run/debug it. In VS Code,
   use **Run Build Task** for the selected tool and **Run and Debug** for its
   CodeLLDB configuration. Both build the selected target before running it.

VS Code setup can install the official **clangd** and **CodeLLDB** extensions.
Its workspace points clangd at this environment's compilation database, including
its generated headers. **Tasks: Run Task → Workbench: choose build target** lets
you build another target; **Workbench: prepare environment** reruns CMake.
CLion uses the full CMake model, including the enabled projects and test targets.
For individual regression tests or libc++ runtime test setup, continue using
the **Tests** category in Workbench; a runtime library is not a standalone debug program.

Enter one program argument per line before the first open, or edit arguments in
the IDE afterward. Reopening preserves existing run arguments and CLion
breakpoints. Use a Dev or Debug environment for source debugging.

Generated projects live under `~/Library/Application Support/LLVMWorkbench/ide/`.
They refer to your real source checkout and build directory, and leave its existing
`.idea` and `.vscode` directories untouched. Open the generated project from
Workbench when changing environments. After editing environment settings, prepare
and open it again. CLion watches the generated environment settings and reloads
its CMake model when they change. If upgrading an already-open project from an
older Workbench build, use **Reload CMake Project** once to enable this tracking.
Avoid building the same environment in Workbench and an IDE at the same time.
If you delete its build outputs, click **Prepare & Open** to restore them.

To prepare the environment and generate the same files from the CLI:

```sh
./llvm-dev --source /path/to/llvm-project --profile Daily ide clion --target clang -- -cc1 example.cpp
./llvm-dev --source /path/to/llvm-project --profile Daily ide vscode --target llc -- input.ll
```

The command prints the project path to open. It does not launch an IDE or install
extensions. Existing IDE run arguments take priority over later CLI arguments.

### CLion reports a compiler-info error while reloading

In CLion 2026.1, the optional Compilation Database fallback can misread PCH
creation commands from LLVM's internal `NATIVE` build. If reload fails with
`GCCCompiler.splitOutput` / `StringIndexOutOfBoundsException`, open **Settings →
Advanced Settings → CMake**, clear **Use Compilation Database
(compile_commands.json) as a fallback resolve configuration**, then reload the
CMake project. This is a CLion-wide workaround: external sub-builds that rely on
fallback databases will no longer be added automatically. The main CMake project,
PCH builds, and LLD linking remain enabled. Workbench does not change this global
IDE preference automatically.

## Run tests

1. Open **Workbench** and select the **Tests** category.
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
