use llvm_dev_core::{cancel_all, dispatch};
use serde_json::json;
use std::{
    env,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::Duration,
};
static INTERRUPTED: AtomicBool = AtomicBool::new(false);
extern "C" fn interrupt(_: i32) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}
fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(2);
    }
}
fn run() -> Result<(), String> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    // Arguments after -- belong exclusively to the selected tool, including --help.
    let tool_args = if let Some(i) = args.iter().position(|s| s == "--") {
        let a = args.split_off(i + 1);
        args.pop();
        a
    } else {
        vec![]
    };
    if args.is_empty() || args.iter().any(|s| s == "--help" || s == "-h") {
        println!("LLVM Workbench — shared Core CLI\n\nllvm-dev [--source PATH] [--profile NAME_OR_ID] COMMAND\n\n  inspect | catalog | profiles | targets | history\n  init --name NAME [--projects LIST] [--backends LIST] [--runtimes LIST] [--mode dev|debug|release]\n  edit --profile NAME [--projects LIST] [--backends LIST] [--runtimes LIST] [--jobs N]\n  clone --profile NAME --name NEW_NAME [--mode dev|debug|release]\n  configure [--dry-run]\n  build TARGET... [--dry-run]\n  run TARGET -- ARG...\n  test PATH [--dry-run]\n  ide clion|vscode [--target TARGET] [-- ARG...]\n\nEnvironment options: --linker system|lld|/absolute/path (init, edit, clone).\n\nEach environment is independent. Lists are comma/semicolon separated.\nOnly environments saved by Workbench are listed. Build directories are never auto-imported.\nUse --json for structured output. Ctrl-C cancels the owned process group.");
        return Ok(());
    }
    let flag = |args: &mut Vec<String>, name: &str| -> bool {
        if let Some(i) = args.iter().position(|x| x == name) {
            args.remove(i);
            true
        } else {
            false
        }
    };
    let option = |args: &mut Vec<String>, name: &str| -> Result<Option<String>, String> {
        if let Some(i) = args.iter().position(|x| x == name) {
            args.remove(i);
            if i >= args.len() {
                return Err(format!("Missing value for {name}"));
            }
            Ok(Some(args.remove(i)))
        } else {
            Ok(None)
        }
    };
    let root = option(&mut args, "--source")?.unwrap_or_else(|| ".".into());
    let selected = option(&mut args, "--profile")?;
    let json_output = flag(&mut args, "--json");
    let dry = flag(&mut args, "--dry-run");
    let cmd = args.first().ok_or("Missing command")?.clone();
    args.remove(0);
    let snapshot = dispatch(json!({"action":"inspect","root":root}))?;
    let root = snapshot["root"].as_str().ok_or("Invalid workspace")?;
    if ["inspect", "catalog", "profiles", "history"].contains(&cmd.as_str()) {
        let value = match cmd.as_str() {
            "catalog" => snapshot["capabilities"].clone(),
            "profiles" => snapshot["profiles"].clone(),
            "history" => dispatch(json!({"action":"history","root":root}))?,
            _ => snapshot,
        };
        println!("{}", serde_json::to_string_pretty(&value).unwrap());
        return Ok(());
    }
    if ["init", "edit", "clone"].contains(&cmd.as_str()) {
        let mut p = if cmd == "init" {
            snapshot["default_profile"].clone()
        } else {
            let name = selected
                .as_ref()
                .ok_or("Specify --profile NAME_OR_ID for edit/clone")?;
            snapshot["profiles"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"] == *name || p["name"] == *name)
                .cloned()
                .ok_or("No matching environment")?
        };
        if cmd == "clone" {
            p["id"] = json!("");
            p["build_dir"] = json!("");
            p["name"] = json!(format!(
                "{} copy",
                p["name"].as_str().unwrap_or("Environment")
            ));
        }
        for (option_name, key) in [
            ("--name", "name"),
            ("--mode", "mode"),
            ("--cc", "cc"),
            ("--cxx", "cxx"),
            ("--linker", "linker"),
        ] {
            if let Some(v) = option(&mut args, option_name)? {
                p[key] = json!(v);
            }
        }
        if let Some(v) = option(&mut args, "--jobs")? {
            p["jobs"] = json!(v.parse::<u32>().map_err(|_| "--jobs must be an integer")?);
        }
        for (option_name, key) in [
            ("--projects", "projects"),
            ("--backends", "backends"),
            ("--runtimes", "runtimes"),
        ] {
            if let Some(v) = option(&mut args, option_name)? {
                p[key] = json!(v
                    .split([',', ';'])
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>());
            }
        }
        if !args.is_empty() {
            return Err(format!("Unrecognized arguments: {args:?}"));
        }
        let p = dispatch(json!({"action":"save_profile","root":root,"profile":p}))?;
        println!("{}", serde_json::to_string_pretty(&p).unwrap());
        return Ok(());
    }
    let all = snapshot["profiles"].as_array().ok_or("No profiles")?;
    let p = if let Some(name) = selected {
        all.iter().find(|p| p["id"] == name || p["name"] == name)
    } else {
        all.first()
    }
    .ok_or("No matching environment. Use init or --profile.")?;
    if cmd == "ide" {
        let target = option(&mut args, "--target")?.unwrap_or_default();
        let ide = args.first().ok_or("Specify clion or vscode")?;
        if args.len() != 1 {
            return Err("Use ide clion|vscode [--target TARGET]".into());
        }
        if !["clion", "vscode"].contains(&ide.as_str()) {
            return Err("Choose CLion or VS Code.".into());
        }
        if dry {
            return Err("Use configure --dry-run to preview environment settings. IDE preparation requires the configured target graph.".into());
        }
        let state = dispatch(json!({"action":"artifacts","root":root,"profile_id":p["id"]}))?;
        if state["configured"] != true
            || state["pending"] == true
            || !std::path::Path::new(p["build_dir"].as_str().ok_or("Missing build directory")?)
                .join("compile_commands.json")
                .is_file()
        {
            let job = dispatch(
                json!({"action":"start","root":root,"profile_id":p["id"],"operation":"configure"}),
            )?;
            wait_for_job(&job, !json_output, false)?;
        }
        let job = dispatch(
            json!({"action":"start","root":root,"profile_id":p["id"],"operation":"ide_headers"}),
        )?;
        wait_for_job(&job, !json_output, false)?;
        let value = dispatch(
            json!({"action":"ide","root":root,"profile_id":p["id"],"ide":ide,"target":target,"arguments":tool_args}),
        )?;
        if json_output {
            println!("{}", serde_json::to_string_pretty(&value).unwrap());
        } else {
            println!("Open in {}: {}", ide, value["path"].as_str().unwrap_or(""));
        }
        return Ok(());
    }
    if cmd == "targets" {
        let value = dispatch(json!({"action":"artifacts","root":root,"profile_id":p["id"]}))?;
        if json_output {
            println!("{}", value);
        } else {
            for a in value["artifacts"].as_array().into_iter().flatten() {
                println!(
                    "{:<32} {:<16} {}",
                    a["name"].as_str().unwrap_or(""),
                    a["kind"].as_str().unwrap_or(""),
                    a["paths"]
                );
            }
        }
        return Ok(());
    }
    if !["configure", "build", "run", "test"].contains(&cmd.as_str()) {
        return Err(format!("Unknown command {cmd}"));
    }
    let mut request = json!({"action":if dry{"plan"}else{"start"},"root":root,"profile_id":p["id"],"operation":cmd});
    match cmd.as_str() {
        "build" => request["targets"] = json!(args),
        "run" => {
            request["target"] = json!(args.first().ok_or("Specify a target")?);
            request["arguments"] = json!(tool_args);
        }
        "test" => request["test_path"] = json!(args.first().ok_or("Specify a test path")?),
        _ => {}
    }
    let value = dispatch(request)?;
    if dry {
        println!("{}", serde_json::to_string_pretty(&value).unwrap());
        return Ok(());
    }
    wait_for_job(&value, !json_output, json_output)
}

fn wait_for_job(
    value: &serde_json::Value,
    show_logs: bool,
    print_json: bool,
) -> Result<(), String> {
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGINT, interrupt as *const () as usize);
        libc::signal(libc::SIGTERM, interrupt as *const () as usize);
    }
    let mut seen = 0;
    loop {
        if INTERRUPTED.load(Ordering::SeqCst) {
            cancel_all();
        }
        let state = dispatch(json!({"action":"poll","id":value["id"]}))?;
        let count = state["line_count"].as_u64().unwrap_or(0);
        let lines = state["lines"].as_array().unwrap();
        if show_logs {
            let start = lines.len().saturating_sub((count - seen) as usize);
            for line in &lines[start..] {
                println!("{}", line.as_str().unwrap_or(""));
            }
        }
        seen = count;
        if state["status"] != "running" {
            if print_json {
                println!("{}", state);
            } else if show_logs {
                println!("{}; log: {}", state["status"], state["log_path"]);
            }
            let code = state["exit_code"].as_i64().unwrap_or(1) as i32;
            if code != 0 {
                std::process::exit(code);
            }
            break;
        }
        thread::sleep(Duration::from_millis(150));
    }
    Ok(())
}
