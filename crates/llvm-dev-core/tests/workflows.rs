use llvm_dev_core::{cmake_set, dispatch};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
struct Fixture {
    root: PathBuf,
    home: PathBuf,
}
impl Fixture {
    fn new() -> Self {
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
        // Tests run serially: Core's persisted state is isolated from the user's app.
        std::env::set_var("LLVM_WORKBENCH_HOME", &home);
        Self {
            root: root.canonicalize().unwrap(),
            home,
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
    let legacy = json!({"version":2,"root":f.root,"profiles":[p.clone()]});
    let file = llvm_dev_core::profiles_file(&f.root);
    fs::write(&file, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let updated = f.call(json!({"action":"inspect"})).unwrap();
    assert_eq!(updated["profiles"][0]["id"], p["id"]);
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
