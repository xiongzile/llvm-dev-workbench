# Testing

Run from the repository root on an Apple Silicon Mac with macOS 14+,
Rust/Cargo, Xcode Command Line Tools, CMake, and Ninja:

```sh
cargo fmt --all -- --check
cargo test --workspace -- --test-threads=1
scripts/build-macos.sh
scripts/test-macos.sh
codesign --verify --deep --strict "dist/LLVM Workbench.app"
```

Tests use isolated application state and small generated CMake fixtures. They do
not build a full LLVM toolchain or modify your saved Workbench environments. Run
Rust tests serially because their state-root override is process-wide.

## Automated coverage

The six Core integration tests cover:

- Checkout-driven component discovery and structured FFI errors.
- Configure, actual output discovery, build-before-run, and executable output.
- Build failures, concurrent-operation rejection, cancellation, and retry.
- Environment definitions surviving deletion of disposable build outputs.
- Build-directory collisions and safe directory-name normalization.
- Legacy application-state build-location migration without moving CMake caches.

The Swift integration check uses the real presentation model and shared Core.
It covers immediate busy state before the first asynchronous suspension,
duplicate-click suppression, startup cancellation, failure reporting, and retry.
It does not automate the rendered UI or native file picker.

## Manual smoke check

1. Open the app and select a disposable LLVM checkout.
2. Create an environment with Clang and the Native backend. Verify the build
   directory is under that checkout and the configuration is in application state.
3. Prepare the environment, select an output, and build it. Click whitespace in
   its row to check that the entire row is selectable.
4. Confirm the build button disables and shows progress immediately. Cancel a
   build and retry; verify the environment is usable afterwards.
5. Run the built executable with `--version`; inspect the command and result.
6. Delete only that environment's disposable build directory. Refresh the app,
   confirm the definition survives, prepare it again, and rebuild.

These checks validate Workbench orchestration. A complete LLVM build and its
regression suites depend on the selected checkout, components, toolchain, and
machine. Linux, Intel Mac, universal app bundles, and notarized distribution
have not been validated for this preview.
