use crate::workspace::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::{fd::AsRawFd, unix::process::CommandExt};
use std::{
    collections::{BTreeMap, VecDeque},
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

pub struct Lock {
    file: File,
}
impl Lock {
    pub fn acquire(key: &str) -> Result<Self> {
        let dir = data_home().join("locks");
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(dir.join(format!("{}.lock", hash(key))))
            .map_err(|e| e.to_string())?;
        #[cfg(unix)]
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(
                "Another operation is using this environment. Wait for it to finish or cancel it."
                    .into(),
            );
        }
        #[cfg(not(unix))]
        return Err("Process locking is currently supported on macOS/Linux only.".into());
        Ok(Self { file })
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Step {
    pub label: String,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Plan {
    pub root: String,
    pub profile_id: String,
    pub build_dir: String,
    pub kind: String,
    pub steps: Vec<Step>,
    pub query: bool,
}
fn required_program(name: &str) -> Result<String> {
    tool_path(name)
        .map(|p| p.to_string_lossy().into())
        .ok_or_else(|| format!("{name} was not found. Install it or add it to PATH."))
}
fn step(root: &Path, label: &str, program: String, args: Vec<String>) -> Step {
    Step {
        label: label.into(),
        program,
        args,
        cwd: root.to_string_lossy().into(),
    }
}
fn configure_values(profile: &Profile) -> BTreeMap<String, String> {
    let mut v: BTreeMap<String, String> = [
        ("CMAKE_BUILD_TYPE", profile.build_type().to_string()),
        ("LLVM_ENABLE_PROJECTS", profile.projects.join(";")),
        ("LLVM_TARGETS_TO_BUILD", profile.backends.join(";")),
        ("LLVM_ENABLE_RUNTIMES", profile.runtimes.join(";")),
        ("LLVM_ENABLE_ASSERTIONS", "ON".into()),
        ("CMAKE_EXPORT_COMPILE_COMMANDS", "ON".into()),
        ("LLVM_INCLUDE_TESTS", "ON".into()),
        ("LLVM_OPTIMIZED_TABLEGEN", "ON".into()),
        ("LLVM_PARALLEL_COMPILE_JOBS", profile.jobs.to_string()),
        ("LLVM_PARALLEL_LINK_JOBS", "1".into()),
        ("LLVM_PARALLEL_TABLEGEN_JOBS", "2".into()),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v))
    .collect();
    if !profile.cc.is_empty() {
        v.insert("CMAKE_C_COMPILER".into(), profile.cc.clone());
    }
    if !profile.cxx.is_empty() {
        v.insert("CMAKE_CXX_COMPILER".into(), profile.cxx.clone());
    }
    if let Some(p) = tool_path("ninja") {
        v.insert("CMAKE_MAKE_PROGRAM".into(), p.to_string_lossy().into());
    }
    if let Some(p) = tool_path("python3") {
        v.insert("Python3_EXECUTABLE".into(), p.to_string_lossy().into());
    }
    v.extend(profile.definitions.clone());
    v
}
pub fn pending(profile: &Profile) -> bool {
    let c = cache(Path::new(&profile.build_dir));
    let values = configure_values(profile);
    [
        "CMAKE_BUILD_TYPE",
        "LLVM_ENABLE_PROJECTS",
        "LLVM_TARGETS_TO_BUILD",
        "LLVM_ENABLE_RUNTIMES",
        "LLVM_PARALLEL_COMPILE_JOBS",
    ]
    .iter()
    .any(|k| c.get(*k) != values.get(*k))
        || profile.definitions.iter().any(|(k, v)| c.get(k) != Some(v))
}
fn strings(v: &Value, key: &str) -> Vec<String> {
    v[key]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
fn field<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(|| format!("Missing {key}"))
}
pub fn make_plan(root: &Path, profile: &Profile, request: &Value) -> Result<Plan> {
    let kind = request["operation"].as_str().unwrap_or("build");
    let mut steps = vec![];
    let build = Path::new(&profile.build_dir);
    let cmake = required_program("cmake")?;
    if kind == "configure" {
        let mut checked = profile.clone();
        validate(root, &mut checked)?;
        if build.join("CMakeCache.txt").exists() {
            check_source(root, profile)?;
        }
        required_program("ninja")?;
        let mut args = vec![
            "-S".into(),
            root.join("llvm").to_string_lossy().into(),
            "-B".into(),
            profile.build_dir.clone(),
            "-G".into(),
            "Ninja".into(),
        ];
        args.extend(
            configure_values(&checked)
                .into_iter()
                .map(|(k, v)| format!("-D{k}={v}")),
        );
        steps.push(step(root, "Preparing environment", cmake, args));
    } else {
        let c = check_source(root, profile)?;
        if pending(profile) {
            return Err("Settings changed. Prepare the environment before building.".into());
        }
        let catalog = artifacts(build)?;
        let mut targets = strings(request, "targets");
        let mut after = None;
        if kind == "run" {
            let name = field(request, "target")?;
            let target = catalog
                .iter()
                .find(|t| t.name == name && t.kind == "EXECUTABLE" && !t.paths.is_empty())
                .ok_or("Choose an executable artifact from this environment.")?;
            targets = vec![name.into()];
            after = Some(step(
                root,
                "Running tool",
                target.paths[0].clone(),
                strings(request, "arguments"),
            ));
        } else if kind == "test" {
            let raw = Path::new(field(request, "test_path")?);
            let path = if raw.is_absolute() {
                raw.to_path_buf()
            } else {
                root.join(raw)
            }
            .canonicalize()
            .map_err(|e| format!("Test path: {e}"))?;
            let relative = path
                .strip_prefix(root)
                .map_err(|_| "Test must be in this source checkout")?;
            let pieces: Vec<_> = relative
                .components()
                .map(|c| c.as_os_str().to_string_lossy().to_string())
                .collect();
            if pieces.len() < 2 || pieces[1] != "test" {
                return Err("Select a regression test under a project's test/ directory.".into());
            }
            let component = pieces[0].as_str();
            let dependency = match component {
                "llvm" => "llvm-test-depends",
                "clang" => "clang-test-depends",
                "lld" => "lld-test-depends",
                "mlir" => "mlir-test-depends",
                "libcxx" => "runtimes-test-depends",
                _ => {
                    return Err(
                        "For this suite, select its check-* target in the test target list.".into(),
                    )
                }
            };
            // Architecture-specific tests must not appear to pass merely because the backend is disabled.
            if component == "llvm"
                && pieces.len() > 2
                && ["CodeGen", "MC"].contains(&pieces[2].as_str())
                && pieces.len() > 3
            {
                let caps = capabilities(root)?;
                let arch = &pieces[3];
                let enabled = list(c.get("LLVM_TARGETS_TO_BUILD"));
                let native = c.get("LLVM_NATIVE_ARCH").cloned().unwrap_or_else(|| {
                    if cfg!(target_arch = "aarch64") {
                        "AArch64"
                    } else {
                        "X86"
                    }
                    .into()
                });
                if caps.backends.contains(arch)
                    && !enabled.contains(arch)
                    && !enabled.contains(&"all".into())
                    && !(enabled.contains(&"Native".into()) && arch == &native)
                {
                    return Err(format!(
                        "Backend {arch} is disabled. Enable it before running these tests."
                    ));
                }
            }
            let test = if component == "libcxx" {
                build.join("runtimes/runtimes-bins").join(relative)
            } else {
                path
            };
            let python = c
                .get("Python3_EXECUTABLE")
                .cloned()
                .filter(|s| !s.is_empty())
                .unwrap_or(required_program("python3")?);
            after = Some(step(
                root,
                "Running regression tests",
                python,
                vec![
                    build.join("bin/llvm-lit").to_string_lossy().into(),
                    "-sv".into(),
                    "-j".into(),
                    profile.jobs.to_string(),
                    test.to_string_lossy().into(),
                ],
            ));
            targets = vec![dependency.into()];
        } else if kind != "build" {
            return Err(format!("Unknown operation {kind}"));
        }
        if targets.is_empty() {
            return Err(
                "Select at least one build target. Building all targets is never implicit.".into(),
            );
        }
        for target in &targets {
            if !catalog.iter().any(|t| &t.name == target) {
                return Err(format!("Target '{target}' is unavailable. Check enabled projects and prepare the environment."));
            }
        }
        let mut args = vec![
            "--build".into(),
            profile.build_dir.clone(),
            "--parallel".into(),
            profile.jobs.to_string(),
            "--target".into(),
        ];
        args.extend(targets);
        steps.push(step(
            root,
            if kind == "test" {
                "Updating test dependencies"
            } else {
                "Building tools"
            },
            cmake,
            args,
        ));
        if let Some(s) = after {
            steps.push(s);
        }
    }
    Ok(Plan {
        root: root.to_string_lossy().into(),
        profile_id: profile.id.clone(),
        build_dir: profile.build_dir.clone(),
        kind: kind.into(),
        steps,
        query: kind == "configure",
    })
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JobState {
    pub id: String,
    pub root: String,
    pub profile_id: String,
    pub title: String,
    pub phase: String,
    pub status: String,
    pub started: u64,
    pub finished: Option<u64>,
    pub exit_code: Option<i32>,
    pub owner_pid: u32,
    pub log_path: String,
    pub line_count: u64,
    pub lines: VecDeque<String>,
}
struct Job {
    state: Mutex<JobState>,
    cancel: AtomicBool,
    log: Mutex<File>,
}
static JOBS: OnceLock<Mutex<BTreeMap<String, Arc<Job>>>> = OnceLock::new();
fn jobs() -> &'static Mutex<BTreeMap<String, Arc<Job>>> {
    JOBS.get_or_init(|| Mutex::new(BTreeMap::new()))
}
fn history_dir(root: &Path) -> PathBuf {
    data_home().join("history").join(workspace_key(root))
}
fn persist(job: &Job) {
    let mut snapshot = job.state.lock().unwrap().clone();
    snapshot.lines.clear();
    let _ = write_json(
        &history_dir(Path::new(&snapshot.root)).join(format!("{}.json", snapshot.id)),
        &snapshot,
    );
}
fn log(job: &Job, line: String) {
    let _ = writeln!(job.log.lock().unwrap(), "{line}");
    let mut state = job.state.lock().unwrap();
    state.line_count += 1;
    state.lines.push_back(line);
    while state.lines.len() > 500 {
        state.lines.pop_front();
    }
}
fn reader(pipe: impl std::io::Read + Send + 'static, job: Arc<Job>) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        for line in BufReader::new(pipe).split(b'\n') {
            match line {
                Ok(bytes) => log(
                    &job,
                    String::from_utf8_lossy(&bytes)
                        .trim_end_matches('\r')
                        .into(),
                ),
                Err(_) => break,
            }
        }
    })
}
fn run_steps(plan: &Plan, job: &Arc<Job>) -> Result<i32> {
    if plan.query {
        let query = Path::new(&plan.build_dir).join(".cmake/api/v1/query");
        fs::create_dir_all(&query).map_err(|e| e.to_string())?;
        fs::write(query.join("codemodel-v2"), "").map_err(|e| e.to_string())?;
    }
    for spec in &plan.steps {
        if job.cancel.load(Ordering::SeqCst) {
            return Ok(130);
        }
        {
            let mut state = job.state.lock().unwrap();
            state.phase = spec.label.clone();
        }
        persist(job);
        log(
            job,
            format!(
                "\n▶ {}\n{}",
                spec.label,
                serde_json::to_string(&json!({"program":spec.program,"args":spec.args})).unwrap()
            ),
        );
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .current_dir(&spec.cwd)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null());
        let mut paths: Vec<PathBuf> =
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
        paths.extend(
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/Applications/CMake.app/Contents/bin",
                "/usr/bin",
                "/bin",
            ]
            .map(PathBuf::from),
        );
        if let Ok(path) = std::env::join_paths(paths) {
            command.env("PATH", path);
        }
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command
            .spawn()
            .map_err(|e| format!("Could not start {}: {e}", spec.program))?;
        let out = reader(child.stdout.take().unwrap(), job.clone());
        let err = reader(child.stderr.take().unwrap(), job.clone());
        let mut terminating = None;
        let status = loop {
            if job.cancel.load(Ordering::SeqCst) {
                if terminating.is_none() {
                    #[cfg(unix)]
                    unsafe {
                        libc::kill(-(child.id() as i32), libc::SIGTERM);
                    }
                    terminating = Some(Instant::now());
                }
                if terminating.is_some_and(|t| t.elapsed() > Duration::from_secs(2)) {
                    #[cfg(unix)]
                    unsafe {
                        libc::kill(-(child.id() as i32), libc::SIGKILL);
                    }
                }
            }
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                if job.cancel.load(Ordering::SeqCst) {
                    #[cfg(unix)]
                    unsafe {
                        libc::kill(-(child.id() as i32), libc::SIGKILL);
                    }
                }
                break status;
            }
            thread::sleep(Duration::from_millis(80));
        };
        let _ = out.join();
        let _ = err.join();
        if job.cancel.load(Ordering::SeqCst) {
            return Ok(130);
        }
        if !status.success() {
            return Ok(status.code().unwrap_or(1));
        }
    }
    Ok(0)
}
pub fn start(plan: Plan) -> Result<Value> {
    let lock = Lock::acquire(&plan.build_dir)?;
    let id = unique_id();
    let dir = history_dir(Path::new(&plan.root));
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let log_path = dir.join(format!("{id}.log"));
    let file = File::create(&log_path).map_err(|e| e.to_string())?;
    let state = JobState {
        id: id.clone(),
        root: plan.root.clone(),
        profile_id: plan.profile_id.clone(),
        title: plan
            .steps
            .first()
            .map(|s| s.label.clone())
            .unwrap_or_default(),
        phase: "Starting".into(),
        status: "running".into(),
        started: now(),
        finished: None,
        exit_code: None,
        owner_pid: std::process::id(),
        log_path: log_path.to_string_lossy().into(),
        line_count: 0,
        lines: VecDeque::new(),
    };
    let job = Arc::new(Job {
        state: Mutex::new(state),
        cancel: AtomicBool::new(false),
        log: Mutex::new(file),
    });
    jobs().lock().unwrap().insert(id.clone(), job.clone());
    persist(&job);
    thread::spawn(move || {
        let result = run_steps(&plan, &job);
        if let Err(message) = &result {
            log(&job, format!("Error: {message}"));
        }
        let code = result.unwrap_or(1);
        // Completion must only become observable once another operation can acquire the build.
        drop(lock);
        {
            let mut state = job.state.lock().unwrap();
            state.exit_code = Some(code);
            state.finished = Some(now());
            state.status = if job.cancel.load(Ordering::SeqCst) {
                "cancelled"
            } else if code == 0 {
                "succeeded"
            } else {
                "failed"
            }
            .into();
            state.phase = match state.status.as_str() {
                "succeeded" => "Completed",
                "cancelled" => "Cancelled",
                _ => "Failed",
            }
            .into();
        }
        persist(&job);
    });
    Ok(json!({"id":id}))
}
pub fn cancel_all() {
    for job in jobs().lock().unwrap().values() {
        job.cancel.store(true, Ordering::SeqCst);
    }
}
pub fn dispatch(request: Value) -> Result<Value> {
    let action = field(&request, "action")?;
    if action == "poll" || action == "cancel" {
        let id = field(&request, "id")?;
        let job = jobs()
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or("Operation not found in this process")?;
        if action == "cancel" {
            job.cancel.store(true, Ordering::SeqCst);
        }
        let state = job.state.lock().unwrap().clone();
        return serde_json::to_value(state).map_err(|e| e.to_string());
    }
    if action == "shutdown" {
        cancel_all();
        return Ok(json!(true));
    }
    if action == "tools" {
        return Ok(tools());
    }
    let root = root_path(field(&request, "root")?)?;
    if action == "inspect" {
        return inspect(&root);
    }
    if action == "preview_profile" {
        let mut profile: Profile =
            serde_json::from_value(request["profile"].clone()).map_err(|e| e.to_string())?;
        validate(&root, &mut profile)?;
        if profile.id.is_empty() {
            profile.build_dir = proposed_build_dir(&root, &profile.name, &profiles(&root)?)
                .to_string_lossy()
                .into();
        }
        return serde_json::to_value(profile).map_err(|e| e.to_string());
    }
    if action == "save_profile" {
        let profile: Profile =
            serde_json::from_value(request["profile"].clone()).map_err(|e| e.to_string())?;
        return serde_json::to_value(save_profile(&root, profile)?).map_err(|e| e.to_string());
    }
    if action == "history" {
        let mut files: Vec<_> = fs::read_dir(history_dir(&root))
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|s| s == "json"))
            .collect();
        files.sort();
        files.reverse();
        let mut records = vec![];
        for p in files.into_iter().take(60) {
            if let Ok(mut record) = read_json(&p) {
                if record["status"] == "running" {
                    let pid = record["owner_pid"].as_u64().unwrap_or(0) as i32;
                    #[cfg(unix)]
                    if pid == 0 || unsafe { libc::kill(pid, 0) } != 0 {
                        record["status"] = json!("interrupted");
                    }
                }
                records.push(record);
            }
        }
        return Ok(json!(records));
    }
    // Serialize planning against profile changes until start has taken its build lock.
    let _settings_guard = if action == "start" {
        Some(Lock::acquire(&format!(
            "settings-{}",
            workspace_key(&root)
        ))?)
    } else {
        None
    };
    let profile = get_profile(&root, field(&request, "profile_id")?)?;
    match action {
        "artifacts" => Ok(
            json!({"artifacts":artifacts(Path::new(&profile.build_dir))?,"configured":Path::new(&profile.build_dir).join("CMakeCache.txt").exists(),"pending":pending(&profile),"cache":cache(Path::new(&profile.build_dir))}),
        ),
        "plan" => {
            serde_json::to_value(make_plan(&root, &profile, &request)?).map_err(|e| e.to_string())
        }
        "start" => start(make_plan(&root, &profile, &request)?),
        _ => Err(format!("Unknown action: {action}")),
    }
}
