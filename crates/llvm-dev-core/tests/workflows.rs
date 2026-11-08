use llvm_dev_core::{cmake_set, dispatch};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::{Mutex, MutexGuard},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
static STATE_HOME: Mutex<()> = Mutex::new(());
struct Fixture {
    root: PathBuf,
    home: PathBuf,
    previous_home: Option<std::ffi::OsString>,
    _state_home: MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        // The override is process-wide, including Core's worker threads.
        let state_home = STATE_HOME.lock().unwrap_or_else(|e| e.into_inner());
        let previous_home = std::env::var_os("LLVM_WORKBENCH_HOME");
        let base = std::env::temp_dir().join(format!(
            "llvm-workbench-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let root = base.join("checkout with spaces");
        let home = base.join("state");
        fs::create_dir_all(root.join("llvm")).unwrap();
        fs::create_dir_all(root.join("clang")).unwrap();
        fs::write(root.join("llvm/CMakeLists.txt"),r#"cmake_minimum_required(VERSION 3.20)
project(WorkbenchFixture LANGUAGES C)
set(LLVM_ALL_PROJECTS "clang;lld;lldb;mlir;polly;flang")
set(LLVM_EXTRA_PROJECTS "clang-tools-extra")
set(LLVM_ALL_TARGETS AArch64 X86 RISCV NVPTX)
set(LLVM_SUPPORTED_RUNTIMES "libcxx;libcxxabi;libunwind;compiler-rt")
# Use LLVM's linker flag mechanism so the fixture really links with the selection.
if(LLVM_USE_LINKER)
  string(APPEND CMAKE_EXE_LINKER_FLAGS " -fuse-ld=${LLVM_USE_LINKER}")
endif()
add_executable(fixture-tool tool.c)
set_target_properties(fixture-tool PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/custom output")
add_custom_target(fail COMMAND "${CMAKE_COMMAND}" -E false)
add_custom_target(slow COMMAND /bin/sh -c "sleep 40 & wait")
"#).unwrap();
        fs::write(
            root.join("llvm/tool.c"),
            "#include <stdio.h>\nint main(void){ puts(\"Workbench fixture ran\"); return 0; }\n",
        )
        .unwrap();
        std::env::set_var("LLVM_WORKBENCH_HOME", &home);
        Self {
            root: root.canonicalize().unwrap(),
            home,
            previous_home,
            _state_home: state_home,
        }
    }
    fn call(&self, mut value: Value) -> Result<Value, String> {
        value["root"] = json!(self.root);
        dispatch(value)
    }
    fn create(&self) -> Value {
        let s = self.call(json!({"action":"inspect"})).unwrap();
        let mut p = s["default_profile"].clone();
        p["projects"] = json!(["polly"]);
        p["cc"] = json!("");
        p["cxx"] = json!("");
        self.call(json!({"action":"save_profile","profile":p}))
            .unwrap()
    }
    fn start(&self, p: &Value, operation: &str, targets: Vec<&str>) -> Value {
        self.call(
            json!({"action":"start","profile_id":p["id"],"operation":operation,"targets":targets}),
        )
        .unwrap()
    }
    fn wait(&self, id: &Value) -> Value {
        let start = Instant::now();
        loop {
            let s = dispatch(json!({"action":"poll","id":id})).unwrap();
            if s["status"] != "running" {
                return s;
            }
            assert!(start.elapsed() < Duration::from_secs(30), "timed out: {s}");
            thread::sleep(Duration::from_millis(70));
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(self.root.parent().unwrap());
        if let Some(home) = &self.previous_home {
            std::env::set_var("LLVM_WORKBENCH_HOME", home);
        } else {
            std::env::remove_var("LLVM_WORKBENCH_HOME");
        }
    }
}
#[test]
fn shared_core_workflow_and_guards() {
    let f = Fixture::new();
    let p = f.create();
    assert_eq!(p["projects"], json!(["polly"])); // Generic checkout project, not a fixed focus recipe.
    assert!(!f.root.join(".llvm-dev").exists());
    let config = f.start(&p, "configure", vec![]);
    let configured = f.wait(&config["id"]);
    assert_eq!(configured["status"], "succeeded", "{configured}");
    let a = f
        .call(json!({"action":"artifacts","profile_id":p["id"]}))
        .unwrap();
    let tool = a["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["name"] == "fixture-tool")
        .unwrap();
    assert_eq!(tool["present"], false);
    assert!(tool["paths"][0].as_str().unwrap().contains("custom output"));
    let run=f.call(json!({"action":"start","operation":"run","profile_id":p["id"],"target":"fixture-tool","arguments":[]})).unwrap();
    let result = f.wait(&run["id"]);
    assert_eq!(result["status"], "succeeded", "{result}");
    assert!(result["lines"]
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l.as_str().unwrap().contains("Workbench fixture ran")));
    let failure = f.start(&p, "build", vec!["fail"]);
    let failed = f.wait(&failure["id"]);
    assert_eq!(failed["status"], "failed");
    assert_ne!(failed["exit_code"], 0);
    // OS lock is held while a long process runs, and cancellation reaps that process group.
    let slow = f.start(&p, "build", vec!["slow"]);
    thread::sleep(Duration::from_millis(300));
    let concurrent=f.call(json!({"action":"start","operation":"build","profile_id":p["id"],"targets":["fixture-tool"]}));
    assert!(concurrent.unwrap_err().contains("Another operation"));
    let mut edited = p.clone();
    edited["backends"] = json!(["Native", "RISCV"]);
    assert!(f
        .call(json!({"action":"save_profile","profile":edited}))
        .unwrap_err()
        .contains("Another operation"));
    dispatch(json!({"action":"cancel","id":slow["id"]})).unwrap();
    let cancelled = f.wait(&slow["id"]);
    assert_eq!(cancelled["status"], "cancelled");
    assert_eq!(cancelled["exit_code"], 130);
    // After cancellation, the same environment can build again.
    let after = f.start(&p, "build", vec!["fixture-tool"]);
    assert_eq!(f.wait(&after["id"])["status"], "succeeded");
    let unknown=f.call(json!({"action":"plan","operation":"build","profile_id":p["id"],"targets":["not-a-real-target"]}));
    assert!(unknown.unwrap_err().contains("unavailable"));
    let mut invalid = p.clone();
    invalid["backends"] = json!(["ImaginaryBackend"]);
    assert!(f
        .call(json!({"action":"save_profile","profile":invalid}))
        .is_err());
    let mut mode = p.clone();
    mode["mode"] = json!("debug");
    assert!(f
        .call(json!({"action":"save_profile","profile":mode}))
        .unwrap_err()
        .contains("Duplicate"));
    let mut runtime = p.clone();
    runtime["runtimes"] = json!(["libcxx"]);
    let normalized = f
        .call(json!({"action":"preview_profile","profile":runtime}))
        .unwrap();
    assert!(normalized["projects"]
        .as_array()
        .unwrap()
        .contains(&json!("clang")));
    assert_eq!(
        normalized["runtimes"],
        json!(["libcxx", "libcxxabi", "libunwind"])
    );
    let history = f.call(json!({"action":"history"})).unwrap();
    assert!(history.as_array().unwrap().len() >= 5);
    assert!(f.home.exists());
}
#[test]
fn component_catalog_tracks_checkout() {
    assert_eq!(
        cmake_set(
            "set(LLVM_ALL_TARGETS\n AArch64 # host\n RISCV\n NewBackend\n)",
            "LLVM_ALL_TARGETS"
        ),
        vec!["AArch64", "RISCV", "NewBackend"]
    );
}

#[test]
fn ide_preparation_restores_generated_headers_without_building_tools() {
    let f = Fixture::new();
    let cmake = f.root.join("llvm/CMakeLists.txt");
    let original = fs::read_to_string(&cmake).unwrap();
    fs::write(
        &cmake,
        format!(
            r#"{original}
add_custom_command(OUTPUT "${{CMAKE_BINARY_DIR}}/generated.h"
  COMMAND "${{CMAKE_COMMAND}}" -E copy
    "${{CMAKE_SOURCE_DIR}}/generated.h.in" "${{CMAKE_BINARY_DIR}}/generated.h"
  DEPENDS "${{CMAKE_SOURCE_DIR}}/generated.h.in")
# MLIR can be enabled transitively, without being in the saved projects list.
add_custom_target(mlir-headers DEPENDS "${{CMAKE_BINARY_DIR}}/generated.h")
target_include_directories(fixture-tool PRIVATE "${{CMAKE_BINARY_DIR}}")
target_precompile_headers(fixture-tool PRIVATE "${{CMAKE_SOURCE_DIR}}/pch.h")
add_dependencies(fixture-tool mlir-headers)
"#
        ),
    )
    .unwrap();
    fs::write(
        f.root.join("llvm/generated.h.in"),
        "#define GENERATED_VALUE 42\n",
    )
    .unwrap();
    fs::write(f.root.join("llvm/pch.h"), "#include \"generated.h\"\n").unwrap();
    let p = f.create();
    let build = PathBuf::from(p["build_dir"].as_str().unwrap());
    let job = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&job["id"])["status"], "succeeded");
    assert!(!build.join("generated.h").exists());
    let probe = || {
        std::process::Command::new("cc")
            .args(["-E", "-x", "c"])
            .arg(format!("-I{}", build.display()))
            .arg(f.root.join("llvm/pch.h"))
            .output()
            .unwrap()
            .status
            .success()
    };
    assert!(
        !probe(),
        "Freshly configured PCH must still lack its generated input"
    );
    for _ in 0..2 {
        let job = f.start(&p, "ide_headers", vec![]);
        let result = f.wait(&job["id"]);
        assert_eq!(result["status"], "succeeded", "{result}");
        assert!(
            probe(),
            "IDE preprocessing should resolve generated headers"
        );
        assert!(!build.join("custom output/fixture-tool").exists());
        assert!(fs::read_to_string(build.join("build.ninja"))
            .unwrap()
            .contains("cmake_pch"));
        // Simulate cleaning generated outputs, then prepare again.
        fs::remove_file(build.join("generated.h")).unwrap();
    }
    fs::remove_file(f.root.join("llvm/generated.h.in")).unwrap();
    let job = f.start(&p, "ide_headers", vec![]);
    assert_eq!(f.wait(&job["id"])["status"], "failed");
}

#[test]
fn ide_preparation_with_no_header_targets_never_builds_all() {
    let f = Fixture::new();
    let p = f.create();
    let build = PathBuf::from(p["build_dir"].as_str().unwrap());
    let job = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&job["id"])["status"], "succeeded");
    let job = f.start(&p, "ide_headers", vec![]);
    assert_eq!(f.wait(&job["id"])["status"], "succeeded");
    assert!(!build.join("custom output/fixture-tool").exists());
}
#[test]
fn null_ffi_is_a_structured_error() {
    unsafe {
        let p = llvm_dev_core::llvmwb_request(std::ptr::null());
        let s = std::ffi::CStr::from_ptr(p).to_str().unwrap();
        let v: Value = serde_json::from_str(s).unwrap();
        assert_eq!(v["ok"], false);
        llvm_dev_core::llvmwb_free(p);
    }
}

#[test]
fn environment_definition_survives_deleting_build_outputs() {
    let f = Fixture::new();
    // Pre-existing CMake builds must not become Workbench environments.
    for relative in ["build/old-build", "llvm/build", "cmake-build-debug"] {
        let dir = f.root.join(relative);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("CMakeCache.txt"), format!(
            "CMAKE_HOME_DIRECTORY:INTERNAL={}/llvm\nCMAKE_BUILD_TYPE:STRING=Debug\nCMAKE_GENERATOR:INTERNAL=Ninja\n", f.root.display()
        )).unwrap();
    }
    assert_eq!(
        f.call(json!({"action":"inspect"})).unwrap()["profiles"],
        json!([])
    );
    let p = f.create();
    let build = PathBuf::from(p["build_dir"].as_str().unwrap());
    assert_eq!(build, f.root.join("build/Development"));
    assert!(!f.home.join("builds").exists());
    let config_file = llvm_dev_core::profiles_file(&f.root);
    assert!(config_file.starts_with(&f.home));
    let definition_before = fs::read(&config_file).unwrap();
    let configured = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&configured["id"])["status"], "succeeded");
    let built = f.start(&p, "build", vec!["fixture-tool"]);
    assert_eq!(f.wait(&built["id"])["status"], "succeeded");
    assert!(build.join("custom output/fixture-tool").exists());

    // This is the user's ordinary cleanup, restricted to our disposable fixture.
    fs::remove_dir_all(f.root.join("build")).unwrap();
    let reopened = f.call(json!({"action":"inspect"})).unwrap();
    assert_eq!(reopened["profiles"], json!([p.clone()]));
    assert_eq!(fs::read(&config_file).unwrap(), definition_before);
    let state = f
        .call(json!({"action":"artifacts","profile_id":p["id"]}))
        .unwrap();
    assert_eq!(state["configured"], false);
    assert_eq!(state["artifacts"], json!([]));
    let restored = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&restored["id"])["status"], "succeeded");
    let rerun = f.call(json!({"action":"start","operation":"run","profile_id":p["id"],"target":"fixture-tool","arguments":[]})).unwrap();
    assert_eq!(f.wait(&rerun["id"])["status"], "succeeded");
    assert!(build.join("custom output/fixture-tool").exists());
    assert_eq!(fs::read(config_file).unwrap(), definition_before);
}

#[test]
fn build_names_do_not_overwrite_existing_or_reserved_paths() {
    let f = Fixture::new();
    let existing = f.root.join("build/Development");
    fs::create_dir_all(&existing).unwrap();
    fs::write(existing.join("keep.txt"), "existing user build").unwrap();
    let first = f.create();
    let second = f.create();
    assert_eq!(
        first["build_dir"],
        json!(f.root.join("build/Development-2"))
    );
    assert_eq!(
        second["build_dir"],
        json!(f.root.join("build/Development-3"))
    );
    assert_eq!(
        fs::read_to_string(existing.join("keep.txt")).unwrap(),
        "existing user build"
    );
    assert_eq!(
        llvm_dev_core::build_directory_name("../Debug / Clang"),
        "Debug-Clang"
    );
    assert_eq!(llvm_dev_core::build_directory_name("断点调试"), "断点调试");
}

#[test]
fn legacy_app_build_paths_get_new_locations_without_moving_cmake_caches() {
    let f = Fixture::new();
    let mut p = f.create();
    let old = f
        .home
        .join("builds")
        .join(llvm_dev_core::workspace_key(&f.root))
        .join(p["id"].as_str().unwrap());
    fs::create_dir_all(&old).unwrap();
    fs::write(
        old.join("CMakeCache.txt"),
        "old absolute paths must stay here",
    )
    .unwrap();
    p["build_dir"] = json!(old);
    p["managed"] = json!(true); // Old schema remains readable.
    p.as_object_mut().unwrap().remove("linker");
    let legacy = json!({"version":2,"root":f.root,"profiles":[p.clone()]});
    let file = llvm_dev_core::profiles_file(&f.root);
    fs::write(&file, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let updated = f.call(json!({"action":"inspect"})).unwrap();
    assert_eq!(updated["profiles"][0]["id"], p["id"]);
    assert_eq!(updated["profiles"][0]["linker"], "system");
    assert_eq!(
        updated["profiles"][0]["build_dir"],
        json!(f.root.join("build/Development"))
    );
    assert_eq!(
        fs::read_to_string(old.join("CMakeCache.txt")).unwrap(),
        "old absolute paths must stay here"
    );
    assert!(!f.root.join("build/Development/CMakeCache.txt").exists());
    let backups: Vec<_> = fs::read_dir(f.home.join("backups")).unwrap().collect();
    assert_eq!(backups.len(), 1);
    let backup = backups[0].as_ref().unwrap().path();
    assert_eq!(llvm_dev_core::read_json(&backup).unwrap(), legacy);
    assert_eq!(
        f.call(json!({"action":"inspect"})).unwrap()["profiles"],
        updated["profiles"]
    );
    assert_eq!(fs::read_dir(f.home.join("backups")).unwrap().count(), 1);
}

#[test]
#[cfg(unix)]
fn linker_switch_relinks_and_clears_stale_detection() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let mut p = f.create();
    let configured = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&configured["id"])["status"], "succeeded");
    let run = f.start(&p, "build", vec!["fixture-tool"]);
    assert_eq!(f.wait(&run["id"])["status"], "succeeded");
    let build = PathBuf::from(p["build_dir"].as_str().unwrap());

    // An executable wrapper proves the compiler actually invokes the chosen
    // linker, without requiring developers to install LLD to run these tests.
    let wrapper = f.home.join("test-linker");
    let marker = f.home.join("linker-called");
    let linker = llvm_dev_core::tool_path("ld").unwrap();
    fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nprintf called >> '{}'\nexec '{}' \"$@\"\n",
            marker.display(),
            linker.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o755)).unwrap();
    p["linker"] = json!(wrapper);
    let p = f
        .call(json!({"action":"save_profile","profile":p}))
        .unwrap();
    assert_eq!(
        f.call(json!({"action":"artifacts","profile_id":p["id"]}))
            .unwrap()["pending"],
        true
    );
    assert!(f.call(json!({"action":"start","operation":"build","profile_id":p["id"],"targets":["fixture-tool"]})).unwrap_err().contains("Prepare the environment"));

    let mut old_cache = fs::read_to_string(build.join("CMakeCache.txt")).unwrap();
    old_cache.push_str("\nLLVM_LINKER_DETECTED:INTERNAL=YES\nLLVM_LINKER_IS_APPLE:INTERNAL=YES\nLLVM_LINKER_SUPPORTS_FAKE:INTERNAL=YES\nLINKER_SUPPORTS_FAKE:INTERNAL=YES\nCXX_SUPPORTS_CUSTOM_LINKER:INTERNAL=FALSE\n");
    fs::write(build.join("CMakeCache.txt"), old_cache).unwrap();
    let config = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&config["id"])["status"], "succeeded");
    let cache = llvm_dev_core::cache(&build);
    for key in [
        "LLVM_LINKER_DETECTED",
        "LLVM_LINKER_IS_APPLE",
        "CXX_SUPPORTS_CUSTOM_LINKER",
        "LLVM_LINKER_SUPPORTS_FAKE",
        "LINKER_SUPPORTS_FAKE",
    ] {
        assert!(
            !cache.contains_key(key),
            "Stale linker probe survived: {key}"
        );
    }
    assert_eq!(
        f.call(json!({"action":"artifacts","profile_id":p["id"]}))
            .unwrap()["pending"],
        false
    );
    let run = f.start(&p, "build", vec!["fixture-tool"]);
    assert_eq!(f.wait(&run["id"])["status"], "succeeded");
    assert!(marker.exists(), "Custom linker was never invoked");
    let calls = fs::read(&marker).unwrap();

    let mut system = p.clone();
    system["linker"] = json!("system");
    let system = f
        .call(json!({"action":"save_profile","profile":system}))
        .unwrap();
    let config = f.start(&system, "configure", vec![]);
    assert_eq!(f.wait(&config["id"])["status"], "succeeded");
    let run = f.start(&system, "build", vec!["fixture-tool"]);
    assert_eq!(f.wait(&run["id"])["status"], "succeeded");
    assert_eq!(
        fs::read(&marker).unwrap(),
        calls,
        "Old linker still invoked after selecting system"
    );
    assert_eq!(llvm_dev_core::cache(&build)["LLVM_USE_LINKER"], "");

    let mut missing = p;
    missing["linker"] = json!(f.home.join("missing-linker"));
    let missing = f
        .call(json!({"action":"save_profile","profile":missing}))
        .unwrap();
    assert!(f
        .call(json!({"action":"plan","operation":"configure","profile_id":missing["id"]}))
        .unwrap_err()
        .contains("Linker is not executable"));
}

#[test]
fn ide_documents_reuse_environment_and_preserve_user_settings() {
    use std::process::Command;
    let f = Fixture::new();
    let p = f.create();
    assert!(f
        .call(json!({"action":"ide","profile_id":p["id"],"ide":"vscode"}))
        .is_err());
    assert_eq!(
        f.wait(&f.start(&p, "configure", vec![])["id"])["status"],
        "succeeded"
    );
    let export = |ide: &str| {
        f.call(json!({"action":"ide","profile_id":p["id"],"ide":ide,"target":"fixture-tool","arguments":["a b","quote\"","$literal"]})).unwrap()
    };
    let v = export("vscode");
    let path = PathBuf::from(v["path"].as_str().unwrap());
    assert!(path.starts_with(&f.home));
    assert!(!f.root.join(".vscode").exists());
    let mut doc: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(doc["settings"]["cmake.buildDirectory"], p["build_dir"]);
    assert!(doc["settings"]["clangd.arguments"][0]
        .as_str()
        .unwrap()
        .ends_with(p["build_dir"].as_str().unwrap()));
    let run = &doc["launch"]["configurations"][0];
    assert!(run["program"].as_str().unwrap().contains("custom output"));
    assert_eq!(run["args"], json!(["a b", "quote\"", "$literal"]));
    let task = doc["tasks"]["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["label"] == run["preLaunchTask"])
        .unwrap();
    let output = Command::new(task["command"].as_str().unwrap())
        .args(
            task["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap()),
        )
        .current_dir(&f.root)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(Command::new(run["program"].as_str().unwrap())
        .output()
        .unwrap()
        .status
        .success());
    doc["settings"]["editor.fontSize"] = json!(19);
    doc["launch"]["configurations"][0]["args"] = json!(["user edit"]);
    fs::write(&path, serde_json::to_vec_pretty(&doc).unwrap()).unwrap();
    export("vscode");
    let updated: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(updated["settings"]["editor.fontSize"], 19);
    assert_eq!(
        updated["launch"]["configurations"][0]["args"],
        json!(["user edit"])
    );
    assert_eq!(updated["tasks"]["tasks"].as_array().unwrap().len(), 3);
    let cl = export("clion");
    let cl = PathBuf::from(cl["path"].as_str().unwrap());
    let workspace = cl.join(".idea/workspace.xml");
    let original = fs::read_to_string(&workspace).unwrap();
    assert!(original.contains("ENABLED=\"true\""));
    assert!(original.contains(p["build_dir"].as_str().unwrap()));
    assert!(!f.root.join("llvm/.idea").exists());
    let cmake = llvm_dev_core::tool_path("cmake").unwrap();
    let result = Command::new(cmake)
        .args([
            "-S",
            f.root.join("llvm").to_str().unwrap(),
            "-B",
            p["build_dir"].as_str().unwrap(),
            "-G",
            "Ninja",
            "-C",
            cl.join("environment.cmake").to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let changed = original.replace(
        "</project>",
        "<component name=\"UserBreakpoint\" /></project>",
    );
    fs::write(&workspace, &changed).unwrap();
    export("clion");
    assert_eq!(fs::read_to_string(&workspace).unwrap(), changed);
    let mut edited = p.clone();
    edited["jobs"] = json!(3);
    f.call(json!({"action":"save_profile","profile":edited}))
        .unwrap();
    assert!(f
        .call(json!({"action":"ide","profile_id":p["id"],"ide":"clion"}))
        .unwrap_err()
        .contains("Settings changed"));
    let bytes = fs::read(&path).unwrap();
    // Refuse to silently discard JSONC/custom content.
    fs::write(&path, b"// user comment\n{}").unwrap();
    assert_eq!(
        f.wait(&f.start(&edited, "configure", vec![])["id"])["status"],
        "succeeded"
    );
    assert!(f
        .call(json!({"action":"ide","profile_id":p["id"],"ide":"vscode"}))
        .unwrap_err()
        .contains("invalid JSON"));
    assert_eq!(fs::read(&path).unwrap(), b"// user comment\n{}");
    fs::write(&path, bytes).unwrap();
}

#[test]
fn clion_tracks_environment_changes_without_reapplying_stale_options() {
    use std::process::Command;
    let f = Fixture::new();
    let cmakelists = f.root.join("llvm/CMakeLists.txt");
    let mut source = fs::read_to_string(&cmakelists).unwrap();
    source.push_str("\nif(\"clang\" IN_LIST LLVM_ENABLE_PROJECTS)\nadd_executable(new-frontend tool.c)\nendif()\n");
    fs::write(&cmakelists, source).unwrap();
    let upstream = f.root.join("user-hook.cmake");
    fs::write(
        &upstream,
        "set(USER_HOOK_RAN YES CACHE STRING \"\" FORCE)\n",
    )
    .unwrap();
    let mut p = f.create();
    p["definitions"] = json!({"CMAKE_PROJECT_INCLUDE_BEFORE":upstream});
    f.call(json!({"action":"save_profile","profile":p}))
        .unwrap();
    assert_eq!(
        f.wait(&f.start(&p, "configure", vec![])["id"])["status"],
        "succeeded"
    );
    let export = || {
        f.call(json!({"action":"ide","profile_id":p["id"],"ide":"clion","target":"fixture-tool"}))
            .unwrap()
    };
    let cl = PathBuf::from(export()["path"].as_str().unwrap());
    let build = PathBuf::from(p["build_dir"].as_str().unwrap());
    fs::write(build.join(".cmake/api/v1/query/cmakeFiles-v1"), "").unwrap();
    let configure_in_ide = || {
        let output = Command::new(llvm_dev_core::tool_path("cmake").unwrap())
            .arg("-S")
            .arg(f.root.join("llvm"))
            .arg("-B")
            .arg(&build)
            .args(["-G", "Ninja", "-C"])
            .arg(cl.join("environment.cmake"))
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    configure_in_ide();
    let catalog = || {
        f.call(json!({"action":"artifacts","profile_id":p["id"]}))
            .unwrap()
    };
    assert!(!catalog()["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["name"] == "new-frontend"));
    let reply = build.join(".cmake/api/v1/reply");
    let tracked = || {
        let mut paths: Vec<_> = fs::read_dir(&reply)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("index-")
            })
            .collect();
        paths.sort();
        let index: Value =
            serde_json::from_slice(&fs::read(paths.last().unwrap()).unwrap()).unwrap();
        let item = index["objects"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["kind"] == "cmakeFiles")
            .unwrap();
        let files: Value = serde_json::from_slice(
            &fs::read(reply.join(item["jsonFile"].as_str().unwrap())).unwrap(),
        )
        .unwrap();
        assert!(files["inputs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["path"] == cl.join("environment.cmake").to_string_lossy().as_ref()));
    };
    tracked();
    // Workbench must be able to add projects despite an older IDE preload script.
    let mut edited = p.clone();
    edited["projects"] = json!(["polly", "clang"]);
    f.call(json!({"action":"save_profile","profile":edited}))
        .unwrap();
    assert_eq!(
        f.wait(&f.start(&edited, "configure", vec![])["id"])["status"],
        "succeeded"
    );
    assert!(catalog()["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["name"] == "new-frontend"));
    let old = fs::read(cl.join("environment.cmake")).unwrap();
    export();
    assert_ne!(fs::read(cl.join("environment.cmake")).unwrap(), old);
    configure_in_ide();
    tracked();
    assert!(catalog()["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["name"] == "new-frontend"));
    assert_eq!(llvm_dev_core::cache(&build)["USER_HOOK_RAN"], "YES");
    // Repeated opens preserve the user's include hook, and no-op exports do not retrigger reloads.
    let modified = fs::metadata(cl.join("environment.cmake"))
        .unwrap()
        .modified()
        .unwrap();
    export();
    assert_eq!(
        fs::metadata(cl.join("environment.cmake"))
            .unwrap()
            .modified()
            .unwrap(),
        modified
    );
    assert!(fs::read_to_string(cl.join("reload.cmake"))
        .unwrap()
        .contains("user-hook.cmake"));
}

#[test]
fn target_history_and_bounded_log_preview() {
    let f = Fixture::new();
    let p = f.create();
    let config = f.start(&p, "configure", vec![]);
    assert_eq!(f.wait(&config["id"])["status"], "succeeded");
    let started = f.start(&p, "build", vec!["fixture-tool"]);
    let result = f.wait(&started["id"]);
    assert_eq!(result["status"], "succeeded");
    assert_eq!(result["operation"], "build");
    assert_eq!(result["targets"], json!(["fixture-tool"]));
    assert!(result["finished"].as_u64().unwrap() >= result["started"].as_u64().unwrap());
    let excerpt = f
        .call(json!({"action":"job_log", "id": result["id"]}))
        .unwrap();
    assert!(!excerpt["lines"].as_array().unwrap().is_empty());
    assert!(f
        .call(json!({"action":"job_log", "id":"../../outside"}))
        .is_err());

    // Existing records must recover only an exact structured CMake command.
    let log = PathBuf::from(result["log_path"].as_str().unwrap());
    let record_path = log.with_extension("json");
    let mut legacy: Value =
        serde_json::from_str(&fs::read_to_string(&record_path).unwrap()).unwrap();
    legacy.as_object_mut().unwrap().remove("targets");
    legacy.as_object_mut().unwrap().remove("operation");
    fs::write(&record_path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let history = f.call(json!({"action":"history"})).unwrap();
    let recovered = history
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == result["id"])
        .unwrap();
    assert_eq!(recovered["targets"], json!(["fixture-tool"]));

    use std::io::Write;
    let mut file = fs::OpenOptions::new().append(true).open(&log).unwrap();
    for n in 0..6000 {
        writeln!(file, "preview line {n:06} abcdefghijklmnopqrstuvwxyz").unwrap();
    }
    let tail = f
        .call(json!({"action":"job_log", "id": result["id"]}))
        .unwrap();
    assert_eq!(tail["lines"].as_array().unwrap().len(), 100);
    assert_eq!(tail["truncated"], true);
    assert!(tail["lines"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .as_str()
        .unwrap()
        .contains("005999"));
}
