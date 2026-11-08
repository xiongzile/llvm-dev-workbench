use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    env, fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub type Result<T> = std::result::Result<T, String>;
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
pub fn unique_id() -> String {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    format!(
        "{}-{}-{}",
        now(),
        std::process::id(),
        SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    )
}
pub fn hash(s: &str) -> String {
    let mut h = 14695981039346656037u64;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    format!("{h:016x}")
}
pub fn read_json(p: &Path) -> Result<Value> {
    serde_json::from_slice(&fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?)
        .map_err(|e| e.to_string())
}
pub fn write_json(p: &Path, value: &impl Serialize) -> Result<()> {
    fs::create_dir_all(p.parent().ok_or("Missing parent directory")?).map_err(|e| e.to_string())?;
    let temporary = p.with_extension(format!("{}.tmp", std::process::id()));
    fs::write(
        &temporary,
        serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::rename(temporary, p).map_err(|e| e.to_string())
}
pub fn data_home() -> PathBuf {
    if let Some(p) = env::var_os("LLVM_WORKBENCH_HOME") {
        return p.into();
    }
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir);
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/LLVMWorkbench")
    } else {
        env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/state"))
            .join("llvm-workbench")
    }
}
pub fn workspace_key(root: &Path) -> String {
    hash(&root.to_string_lossy())
}
pub fn root_path(input: &str) -> Result<PathBuf> {
    let p = Path::new(input)
        .canonicalize()
        .map_err(|e| format!("Cannot open {input}: {e}"))?;
    for root in p.ancestors() {
        if root.join("llvm/CMakeLists.txt").is_file() && root.join("clang").is_dir() {
            return Ok(root.into());
        }
    }
    Err("Choose an LLVM monorepo containing llvm/CMakeLists.txt and clang/.".into())
}
pub fn cmake_set(text: &str, name: &str) -> Vec<String> {
    let needle = format!("set({name}");
    let Some(start) = text.find(&needle) else {
        return vec![];
    };
    let rest = &text[start + needle.len()..];
    if !rest.starts_with(char::is_whitespace) {
        return vec![];
    }
    let body = rest.split(')').next().unwrap_or("");
    body.lines()
        .map(|l| l.split('#').next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
        .split(|c: char| c.is_whitespace() || c == '"' || c == ';')
        .filter(|s| !s.is_empty() && !s.contains('$'))
        .map(str::to_owned)
        .collect()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Capabilities {
    pub projects: Vec<String>,
    pub backends: Vec<String>,
    pub runtimes: Vec<String>,
}
pub fn capabilities(root: &Path) -> Result<Capabilities> {
    let text = fs::read_to_string(root.join("llvm/CMakeLists.txt")).map_err(|e| e.to_string())?;
    let mut projects = cmake_set(&text, "LLVM_ALL_PROJECTS");
    projects.extend(cmake_set(&text, "LLVM_EXTRA_PROJECTS"));
    projects.sort();
    projects.dedup();
    let mut backends = vec!["Native".into()];
    backends.extend(cmake_set(&text, "LLVM_ALL_TARGETS"));
    let mut runtimes = cmake_set(&text, "LLVM_SUPPORTED_RUNTIMES");
    if runtimes.is_empty() {
        runtimes = cmake_set(
            &fs::read_to_string(root.join("runtimes/CMakeLists.txt")).unwrap_or_default(),
            "LLVM_SUPPORTED_RUNTIMES",
        );
    }
    Ok(Capabilities {
        projects,
        backends,
        runtimes,
    })
}
pub fn cache(build: &Path) -> BTreeMap<String, String> {
    fs::read_to_string(build.join("CMakeCache.txt"))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.starts_with(['#', '/']))
        .filter_map(|l| {
            let (k, v) = l.split_once('=')?;
            Some((k.split_once(':')?.0.into(), v.into()))
        })
        .collect()
}
pub fn list(value: Option<&String>) -> Vec<String> {
    value
        .map(|s| {
            s.split(';')
                .filter(|x| !x.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub build_dir: String,
    pub projects: Vec<String>,
    pub backends: Vec<String>,
    pub runtimes: Vec<String>,
    pub mode: String,
    pub jobs: u32,
    pub cc: String,
    pub cxx: String,
    #[serde(default)]
    pub definitions: BTreeMap<String, String>,
}
impl Profile {
    pub fn build_type(&self) -> &str {
        match self.mode.as_str() {
            "debug" => "Debug",
            "release" => "Release",
            _ => "RelWithDebInfo",
        }
    }
}
pub fn profiles_file(root: &Path) -> PathBuf {
    data_home()
        .join("workspaces")
        .join(format!("{}.json", workspace_key(root)))
}
fn stored_profiles(root: &Path) -> Result<Vec<Profile>> {
    let path = profiles_file(root);
    if !path.exists() {
        return Ok(vec![]);
    }
    serde_json::from_value(read_json(&path)?["profiles"].clone()).map_err(|e| {
        format!(
            "Cannot read environment definitions at {}: {e}",
            path.display()
        )
    })
}
pub fn profiles(root: &Path) -> Result<Vec<Profile>> {
    stored_profiles(root)
}
pub fn get_profile(root: &Path, id: &str) -> Result<Profile> {
    profiles(root)?
        .into_iter()
        .find(|p| p.id == id)
        .ok_or_else(|| "Environment no longer exists. Reload the workspace.".into())
}

/// A readable directory name, always a single path component.
pub fn build_directory_name(name: &str) -> String {
    let mut result = String::new();
    for c in name.trim().chars() {
        if c.is_alphanumeric() || c == '_' || c == '-' {
            result.push(c);
        } else if !result.ends_with('-') {
            result.push('-');
        }
    }
    let result = result.trim_matches('-');
    if result.is_empty() {
        "environment".into()
    } else {
        result.chars().take(80).collect()
    }
}
pub fn proposed_build_dir(root: &Path, name: &str, all: &[Profile]) -> PathBuf {
    let base = build_directory_name(name);
    for suffix in 1u64.. {
        let name = if suffix == 1 {
            base.clone()
        } else {
            format!("{base}-{suffix}")
        };
        let path = root.join("build").join(name);
        let key = path.to_string_lossy().to_lowercase();
        // Definitions reserve paths even when their build outputs have been deleted.
        if path.symlink_metadata().is_err()
            && !all.iter().any(|p| p.build_dir.to_lowercase() == key)
        {
            return path;
        }
    }
    unreachable!()
}
fn persist_profiles(root: &Path, all: &[Profile]) -> Result<()> {
    write_json(
        &profiles_file(root),
        &json!({"version":3,"root":root,"profiles":all}),
    )
}
fn sync_profiles(root: &Path) -> Result<Vec<Profile>> {
    let _settings = crate::operations::Lock::acquire(&format!("settings-{}", workspace_key(root)))?;
    let stored = stored_profiles(root)?;
    let mut all = profiles(root)?;
    let legacy_root = data_home().join("builds").join(workspace_key(root));
    let mut migrated = false;
    for index in 0..all.len() {
        if Path::new(&all[index].build_dir).starts_with(&legacy_root) {
            // A running legacy build keeps its path until the next inspection.
            let Ok(_build) = crate::operations::Lock::acquire(&all[index].build_dir) else {
                continue;
            };
            all[index].build_dir = proposed_build_dir(root, &all[index].name, &all)
                .to_string_lossy()
                .into();
            migrated = true;
        }
    }
    if serde_json::to_value(&all).unwrap() != serde_json::to_value(&stored).unwrap() {
        if migrated {
            write_json(
                &data_home().join("backups").join(format!(
                    "{}-{}.json",
                    workspace_key(root),
                    unique_id()
                )),
                &read_json(&profiles_file(root))?,
            )?;
        }
        persist_profiles(root, &all)?;
    }
    Ok(all)
}
pub fn validate(root: &Path, profile: &mut Profile) -> Result<()> {
    if profile.name.trim().is_empty() {
        return Err("Environment name is required.".into());
    }
    if !["dev", "debug", "release"].contains(&profile.mode.as_str()) {
        return Err("Invalid build mode.".into());
    }
    if !(1..=128).contains(&profile.jobs) {
        return Err("Compile jobs must be between 1 and 128.".into());
    }
    let caps = capabilities(root)?;
    for (kind, selected, available) in [
        ("project", &profile.projects, &caps.projects),
        ("backend", &profile.backends, &caps.backends),
        ("runtime", &profile.runtimes, &caps.runtimes),
    ] {
        for name in selected {
            if !available.contains(name) {
                return Err(format!("Unsupported {kind} in this checkout: {name}"));
            }
        }
    }
    if profile.backends.is_empty() {
        profile.backends.push("Native".into());
    }
    // CMake itself decides other project dependencies. Bootstrap runtimes need the built compiler.
    if !profile.runtimes.is_empty()
        || profile
            .projects
            .iter()
            .any(|p| ["clang-tools-extra", "lldb", "flang"].contains(&p.as_str()))
    {
        if !profile.projects.contains(&"clang".into()) {
            profile.projects.push("clang".into());
        }
    }
    if profile.runtimes.contains(&"libcxx".into()) {
        for runtime in ["libcxxabi", "libunwind"] {
            if caps.runtimes.contains(&runtime.into())
                && !profile.runtimes.contains(&runtime.into())
            {
                profile.runtimes.push(runtime.into());
            }
        }
    }
    for p in &profile.projects {
        if profile.runtimes.contains(p) {
            return Err(format!("{p} appears in both projects and runtimes."));
        }
    }
    for k in profile.definitions.keys() {
        if [
            "CMAKE_HOME_DIRECTORY",
            "CMAKE_BUILD_TYPE",
            "LLVM_ENABLE_PROJECTS",
            "LLVM_ENABLE_RUNTIMES",
            "LLVM_TARGETS_TO_BUILD",
            "CMAKE_C_COMPILER",
            "CMAKE_CXX_COMPILER",
        ]
        .contains(&k.as_str())
        {
            return Err(format!("Set {k} using the dedicated environment controls."));
        }
    }
    Ok(())
}
pub fn save_profile(root: &Path, mut profile: Profile) -> Result<Profile> {
    let _guard = crate::operations::Lock::acquire(&format!("settings-{}", workspace_key(root)))?;
    validate(root, &mut profile)?;
    let mut all = profiles(root)?;
    let _build_guard;
    if profile.id.is_empty() {
        profile.id = format!("env-{}", unique_id());
        profile.build_dir = proposed_build_dir(root, &profile.name, &all)
            .to_string_lossy()
            .into();
    } else {
        let old = all
            .iter()
            .find(|p| p.id == profile.id)
            .ok_or("Unknown environment")?;
        _build_guard = crate::operations::Lock::acquire(&old.build_dir)?;
        profile.build_dir = old.build_dir.clone();
        if Path::new(&old.build_dir).join("CMakeCache.txt").exists()
            && (old.mode != profile.mode || old.cc != profile.cc || old.cxx != profile.cxx)
        {
            return Err("Build mode or compiler changed. Duplicate the environment to keep the existing build.".into());
        }
    }
    all.retain(|p| p.id != profile.id);
    all.push(profile.clone());
    persist_profiles(root, &all)?;
    Ok(profile)
}
pub fn tool_path(name: &str) -> Option<PathBuf> {
    let direct = Path::new(name);
    if direct.is_absolute() {
        return direct.is_file().then(|| direct.into());
    }
    let mut dirs: Vec<PathBuf> =
        env::split_paths(&env::var_os("PATH").unwrap_or_default()).collect();
    dirs.extend(
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/CMake.app/Contents/bin",
            "/usr/bin",
            "/bin",
        ]
        .map(PathBuf::from),
    );
    dirs.into_iter().map(|p| p.join(name)).find(|p| p.is_file())
}
pub fn tools() -> Value {
    json!({"cmake":tool_path("cmake"),"ninja":tool_path("ninja"),"python":tool_path("python3"),"cc":tool_path("clang"),"cxx":tool_path("clang++")})
}
pub fn default_profile() -> Profile {
    Profile {
        id: String::new(),
        name: "Development".into(),
        build_dir: String::new(),
        projects: vec![],
        backends: vec!["Native".into()],
        runtimes: vec![],
        mode: "dev".into(),
        jobs: 8,
        cc: tool_path("clang")
            .map(|p| p.to_string_lossy().into())
            .unwrap_or_default(),
        cxx: tool_path("clang++")
            .map(|p| p.to_string_lossy().into())
            .unwrap_or_default(),
        definitions: BTreeMap::new(),
    }
}
pub fn inspect(root: &Path) -> Result<Value> {
    let profiles = sync_profiles(root)?;
    Ok(
        json!({"default_profile":default_profile(),"root":root,"profiles_file":profiles_file(root),"name":root.file_name().unwrap_or_default().to_string_lossy(),"profiles":profiles,"capabilities":capabilities(root)?,"tools":tools()}),
    )
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Artifact {
    pub name: String,
    pub kind: String,
    pub paths: Vec<String>,
    pub present: bool,
    pub description: String,
}
pub fn description(name: &str) -> String {
    match name {
        "clang" => "C / C++ 前端与编译驱动",
        "llc" => "LLVM IR / MIR 到目标机器码",
        "opt" => "LLVM IR 优化与分析",
        "llvm-mc" => "汇编与指令编码",
        "FileCheck" => "回归测试输出检查",
        "clangd" => "C / C++ 语言服务",
        "clang-tidy" => "Clang 代码检查",
        "mlir-opt" => "MLIR 转换与优化",
        "lld" => "链接器",
        _ => "CMake 构建目标",
    }
    .into()
}
pub fn artifacts(build: &Path) -> Result<Vec<Artifact>> {
    let reply = build.join(".cmake/api/v1/reply");
    let mut indexes: Vec<_> = fs::read_dir(&reply)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("index-"))
        .map(|e| e.path())
        .collect();
    indexes.sort();
    let mut result = vec![];
    if let Some(index) = indexes.last() {
        let doc = read_json(index)?;
        if let Some(model_ref) = doc["objects"]
            .as_array()
            .and_then(|a| a.iter().find(|x| x["kind"] == "codemodel"))
        {
            let model =
                read_json(&reply.join(model_ref["jsonFile"].as_str().ok_or("Invalid codemodel")?))?;
            for cfg in model["configurations"]
                .as_array()
                .ok_or("Invalid configurations")?
            {
                for item in cfg["targets"].as_array().ok_or("Invalid targets")? {
                    let target =
                        read_json(&reply.join(item["jsonFile"].as_str().ok_or("Invalid target")?))?;
                    if target["isAbstract"] == true {
                        continue;
                    }
                    let name = target["name"].as_str().unwrap_or("").to_string();
                    let paths: Vec<String> = target["artifacts"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v["path"].as_str())
                        .map(|p| build.join(p).to_string_lossy().into())
                        .collect();
                    let present = !paths.is_empty() && paths.iter().all(|p| Path::new(p).exists());
                    result.push(Artifact {
                        description: description(&name),
                        name,
                        kind: target["type"].as_str().unwrap_or("UTILITY").into(),
                        paths,
                        present,
                    });
                }
            }
            result.sort_by(|a, b| a.name.cmp(&b.name));
            return Ok(result);
        }
    }
    if !build.join("CMakeCache.txt").exists() {
        return Ok(vec![]);
    }
    let c = cache(build);
    let ninja = c
        .get("CMAKE_MAKE_PROGRAM")
        .map(PathBuf::from)
        .or_else(|| tool_path("ninja"))
        .ok_or("Ninja not found")?;
    let output = std::process::Command::new(ninja)
        .arg("-C")
        .arg(build)
        .args(["-t", "targets", "all"])
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).into());
    }
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if let Some((name, "phony")) = line.rsplit_once(": ") {
            if !name.contains('/') {
                result.push(Artifact {
                    name: name.into(),
                    kind: "UTILITY".into(),
                    paths: vec![],
                    present: false,
                    description: description(name),
                });
            }
        }
    }
    result.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(result)
}
pub fn check_source(root: &Path, profile: &Profile) -> Result<BTreeMap<String, String>> {
    let c = cache(Path::new(&profile.build_dir));
    if c.is_empty() {
        return Err("Environment is not configured. Prepare it first.".into());
    }
    if c.get("CMAKE_HOME_DIRECTORY")
        .and_then(|s| Path::new(s).canonicalize().ok())
        != root.join("llvm").canonicalize().ok()
    {
        return Err("This build belongs to a different source checkout.".into());
    }
    if c.get("CMAKE_GENERATOR").map(String::as_str) != Some("Ninja") {
        return Err("This version supports single-configuration Ninja builds.".into());
    }
    Ok(c)
}
