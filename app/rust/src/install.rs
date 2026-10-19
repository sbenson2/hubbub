//! What the Windows installer (Velopack) needs from the app: the `hubbub://` registration, the
//! start-at-login entry and the install/update/uninstall hooks. The runner (`main.cpp`) loads this
//! library first thing in `wWinMain` and calls `hubbub_startup` before Flutter exists, because
//! Velopack runs a hook by launching the exe with `--veloapp-*` and expects it to act and exit
//! within seconds. Doing it here keeps the hook logic next to the crate that defines it, and the
//! same code serves the per-launch registration. Everything touching the registry goes through
//! [`Registry`], so the rules are tested with a fake.
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;

pub const PROTOCOL_KEY: &str = r"Software\Classes\hubbub";
pub const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
pub const RUN_NAME: &str = "Hubbub";
/// Passed by the Run entry so a login start sits in the tray instead of opening the window.
pub const BACKGROUND_ARG: &str = "--background";

/// The slice of the current user's registry (HKCU) the installer touches.
pub trait Registry {
    /// Sets a string value; `name` of `None` is the key's default value. Creates the key.
    fn set(&self, key: &str, name: Option<&str>, value: &str) -> Result<()>;
    fn get(&self, key: &str, name: Option<&str>) -> Option<String>;
    /// Missing values are not an error.
    fn delete_value(&self, key: &str, name: &str) -> Result<()>;
    /// Missing keys are not an error.
    fn delete_tree(&self, key: &str) -> Result<()>;
}

/// Where this exe runs from. Velopack installs to `<root>\current\` with `<root>\Update.exe`
/// next to it; anything else (the build folder, a zip someone extracted) is a dev run.
#[derive(Debug, PartialEq, Eq)]
pub enum Layout {
    Installed { root: PathBuf },
    Dev,
}

pub fn layout(exe: &Path) -> Layout {
    let current = exe.parent();
    let root = current.and_then(Path::parent);
    match (current, root) {
        (Some(c), Some(r))
            if c.file_name().is_some_and(|n| n.eq_ignore_ascii_case("current"))
                && r.join("Update.exe").is_file() =>
        {
            Layout::Installed { root: r.to_path_buf() }
        }
        _ => Layout::Dev,
    }
}

/// The exe a link or the login entry should start. An installed copy always lives at
/// `<root>\current\<exe>`: Velopack swaps the folder's contents on update and never moves it, so
/// that path outlives every update. A dev run points at itself (the build folder), as it always did.
pub fn launch_target(exe: &Path) -> PathBuf {
    match (layout(exe), exe.file_name()) {
        (Layout::Installed { root }, Some(name)) => root.join("current").join(name),
        _ => exe.to_path_buf(),
    }
}

fn protocol_command(target: &Path) -> String {
    format!("\"{}\" \"%1\"", target.display())
}

fn run_command(target: &Path) -> String {
    format!("\"{}\" {BACKGROUND_ARG}", target.display())
}

/// Points `hubbub://` at this exe for the current user. No admin needed.
pub fn register_protocol(reg: &dyn Registry, exe: &Path) -> Result<()> {
    reg.set(PROTOCOL_KEY, None, "URL:hubbub")?;
    reg.set(PROTOCOL_KEY, Some("URL Protocol"), "")?;
    reg.set(
        &format!(r"{PROTOCOL_KEY}\shell\open\command"),
        None,
        &protocol_command(&launch_target(exe)),
    )
}

/// True when the value sits inside `root` (an install being removed must not take a dev run's
/// registration with it).
fn points_into(value: &str, root: &Path) -> bool {
    // With a trailing separator, so `...\Hubbub` does not match `...\HubbubOther\...`.
    let root = format!("{}{}", root.display().to_string().trim_end_matches(['\\', '/']), std::path::MAIN_SEPARATOR);
    value.to_ascii_lowercase().contains(&root.to_ascii_lowercase())
}

/// True when `command` (a registry command line, exe path first and quoted) starts an installed
/// copy of Hubbub that still exists.
fn runs_installed_copy(command: &str) -> bool {
    let Some(exe) = command.trim_start().strip_prefix('"').and_then(|c| c.split('"').next()) else {
        return false;
    };
    matches!(layout(Path::new(exe)), Layout::Installed { .. })
}

/// The rule for a dev run: the installed copy wins. A dev run (build folder, extracted zip)
/// registers itself only when the current registration is absent or points at something else;
/// it never takes `hubbub://` or the login entry away from a live install.
fn dev_yields(reg: &dyn Registry, exe: &Path, key: &str, name: Option<&str>) -> bool {
    layout(exe) == Layout::Dev && reg.get(key, name).is_some_and(|c| runs_installed_copy(&c))
}

/// What every ordinary launch does: keep `hubbub://` pointing at a copy that exists, unless this
/// is a dev run and an installed copy already owns it.
pub fn register_on_launch(reg: &dyn Registry, exe: &Path) -> Result<()> {
    if dev_yields(reg, exe, &format!(r"{PROTOCOL_KEY}\shell\open\command"), None) {
        return Ok(());
    }
    register_protocol(reg, exe)
}

/// Launches that must not touch the registry or pay for it: `--quit` and a link being forwarded
/// to the running instance.
pub fn registers_on_launch(args: &[String]) -> bool {
    !args.iter().any(|a| a.eq_ignore_ascii_case("--quit") || a.to_ascii_lowercase().starts_with("hubbub:"))
}

pub fn start_at_login(reg: &dyn Registry) -> bool {
    reg.get(RUN_KEY, Some(RUN_NAME)).is_some()
}

/// Adds or removes the login entry (HKCU `Run`, the same place Discord uses).
pub fn set_start_at_login(reg: &dyn Registry, exe: &Path, on: bool) -> Result<()> {
    if on {
        if dev_yields(reg, exe, RUN_KEY, Some(RUN_NAME)) {
            return Ok(()); // a dev run never repoints an install's login entry at a build folder
        }
        reg.set(RUN_KEY, Some(RUN_NAME), &run_command(&launch_target(exe)))
    } else {
        reg.delete_value(RUN_KEY, RUN_NAME)
    }
}

/// Install hook: both registrations, with start at login on by default. Only the install does
/// that; an update leaves the user's choice alone.
pub fn on_install(reg: &dyn Registry, exe: &Path) -> Result<()> {
    register_protocol(reg, exe)?;
    set_start_at_login(reg, exe, true)
}

/// Update hook: the files moved, so make the registrations point at the new copy again.
pub fn on_update(reg: &dyn Registry, exe: &Path) -> Result<()> {
    register_protocol(reg, exe)?;
    if start_at_login(reg) {
        set_start_at_login(reg, exe, true)?;
    }
    Ok(())
}

/// Uninstall hook: removes what this install registered, and only that.
pub fn on_uninstall(reg: &dyn Registry, exe: &Path) -> Result<()> {
    let Layout::Installed { root } = layout(exe) else { return Ok(()) };
    let command = reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None);
    if command.is_some_and(|c| points_into(&c, &root)) {
        reg.delete_tree(PROTOCOL_KEY)?;
    }
    if reg.get(RUN_KEY, Some(RUN_NAME)).is_some_and(|c| points_into(&c, &root)) {
        reg.delete_value(RUN_KEY, RUN_NAME)?;
    }
    Ok(())
}

/// The install's own `livekit-server.exe` processes: the ones running from `<root>\current\`,
/// whatever their name is spelled like. Matched by path, never by image name, so another copy's
/// server (a dev build, the owner's other install) is not touched.
#[cfg(windows)]
fn install_servers(sys: &sysinfo::System, root: &Path) -> Vec<sysinfo::Pid> {
    let dir = format!("{}\\current\\", root.display().to_string().trim_end_matches(['\\', '/']));
    sys.processes()
        .iter()
        .filter(|(_, p)| {
            p.exe().is_some_and(|e| {
                let e = e.display().to_string();
                e.to_ascii_lowercase().starts_with(&dir.to_ascii_lowercase())
                    && e.to_ascii_lowercase().ends_with("livekit-server.exe")
            })
        })
        .map(|(pid, _)| *pid)
        .collect()
}

/// Called right before the updater is told to swap `<root>\current\`: the hub's shutdown has
/// normally stopped LiveKit already (it awaits the child's exit), so this usually returns at
/// once. If a server from this install is somehow still alive (the shutdown failed or timed
/// out), wait up to `wait` for it to go, then kill it: a running exe in `current\` makes the
/// swap fail. Returns how many had to be killed.
#[cfg(windows)]
pub fn settle_install_servers(root: &Path, wait: std::time::Duration) -> usize {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let me = sysinfo::get_current_pid().ok();
    let scan = |sys: &mut System| {
        sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().with_exe(UpdateKind::Always),
        );
        install_servers(sys, root).into_iter().filter(|p| Some(*p) != me).collect::<Vec<_>>()
    };
    let mut sys = System::new();
    let deadline = std::time::Instant::now() + wait;
    let mut alive = scan(&mut sys);
    while !alive.is_empty() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(100));
        alive = scan(&mut sys);
    }
    for pid in &alive {
        if let Some(p) = sys.process(*pid) {
            eprintln!("hubbub: livekit-server {pid} outlived the shutdown; killing it before the update");
            p.kill();
        }
    }
    if !alive.is_empty() {
        let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !scan(&mut sys).is_empty() && std::time::Instant::now() < until {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
    alive.len()
}

#[cfg(windows)]
pub use win::WinRegistry;

#[cfg(windows)]
mod win {
    use super::Registry;
    use anyhow::{bail, Result};
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::System::Registry::*;

    pub struct WinRegistry;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    fn check(what: &str, code: u32) -> Result<()> {
        // ERROR_FILE_NOT_FOUND (2) on a delete means it was already gone.
        if code != 0 && code != 2 {
            bail!("{what} failed with {code}");
        }
        Ok(())
    }

    impl Registry for WinRegistry {
        fn set(&self, key: &str, name: Option<&str>, value: &str) -> Result<()> {
            unsafe {
                let mut h: HKEY = null_mut();
                let k = wide(key);
                let r = RegCreateKeyExW(HKEY_CURRENT_USER, k.as_ptr(), 0, null(), 0, KEY_SET_VALUE, null(), &mut h, null_mut());
                check("RegCreateKeyEx", r)?;
                let n = name.map(wide);
                let v = wide(value);
                let r = RegSetValueExW(
                    h,
                    n.as_ref().map_or(null(), |n| n.as_ptr()),
                    0,
                    REG_SZ,
                    v.as_ptr() as *const u8,
                    (v.len() * 2) as u32,
                );
                RegCloseKey(h);
                check("RegSetValueEx", r)
            }
        }

        fn get(&self, key: &str, name: Option<&str>) -> Option<String> {
            unsafe {
                let k = wide(key);
                let n = name.map(wide);
                let np = n.as_ref().map_or(null(), |n| n.as_ptr());
                let mut bytes = 0u32;
                if RegGetValueW(HKEY_CURRENT_USER, k.as_ptr(), np, RRF_RT_REG_SZ, null_mut(), null_mut(), &mut bytes) != 0 {
                    return None;
                }
                let mut buf = vec![0u16; bytes as usize / 2 + 1];
                let mut size = (buf.len() * 2) as u32;
                if RegGetValueW(HKEY_CURRENT_USER, k.as_ptr(), np, RRF_RT_REG_SZ, null_mut(), buf.as_mut_ptr() as *mut _, &mut size) != 0 {
                    return None;
                }
                let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
                Some(String::from_utf16_lossy(&buf[..len]))
            }
        }

        fn delete_value(&self, key: &str, name: &str) -> Result<()> {
            unsafe {
                let r = RegDeleteKeyValueW(HKEY_CURRENT_USER, wide(key).as_ptr(), wide(name).as_ptr());
                check("RegDeleteKeyValue", r)
            }
        }

        fn delete_tree(&self, key: &str) -> Result<()> {
            unsafe { check("RegDeleteTree", RegDeleteTreeW(HKEY_CURRENT_USER, wide(key).as_ptr())) }
        }
    }
}

/// True when Velopack restarted this process after applying an update; the pending-update check
/// at startup skips then, so a package that cannot apply never loops.
static RESTARTED: AtomicBool = AtomicBool::new(false);

#[cfg(windows)]
fn real_registry() -> win::WinRegistry {
    win::WinRegistry
}

/// First call of `wWinMain`. Runs a Velopack hook when the exe was launched for one (and then
/// exits the process), and otherwise registers `hubbub://` for this launch. Auto-apply of a
/// downloaded update is off here: a second launch (a link click) must not swap the files under
/// the instance that is running; [`hubbub_apply_pending`] does that, from the instance itself.
#[no_mangle]
pub extern "C" fn hubbub_startup() {
    let _ = std::panic::catch_unwind(|| {
        #[cfg(windows)]
        {
            let Ok(exe) = std::env::current_exe() else { return };
            let reg = real_registry();
            velopack::VelopackApp::build()
                .set_auto_apply_on_startup(false)
                .on_after_install_fast_callback(|_| {
                    let _ = on_install(&reg, &exe);
                })
                .on_after_update_fast_callback(|_| {
                    let _ = on_update(&reg, &exe);
                })
                .on_before_uninstall_fast_callback(|_| {
                    let _ = on_uninstall(&reg, &exe);
                })
                .on_restarted(|_| RESTARTED.store(true, Ordering::SeqCst))
                .run();
            let args: Vec<String> = std::env::args().skip(1).collect();
            if registers_on_launch(&args) {
                let _ = register_on_launch(&reg, &exe);
            }
        }
    });
}

/// Called by the runner once it is the only instance, before any window exists: if an update was
/// downloaded (and not yet applied because the app was never quit cleanly, e.g. a log-off), apply
/// it now and relaunch with the same arguments. Returns when there is nothing to apply.
#[no_mangle]
pub extern "C" fn hubbub_apply_pending() {
    let _ = std::panic::catch_unwind(|| {
        if RESTARTED.load(Ordering::SeqCst) {
            return;
        }
        let Ok(manager) = velopack::UpdateManager::new(velopack::sources::NoneSource {}, None, None) else {
            return; // a dev run: not installed
        };
        if let Some(asset) = manager.get_update_pending_restart() {
            let args: Vec<String> = std::env::args().skip(1).collect();
            let _ = manager.apply_updates_and_restart_with_args(&asset, &args);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    /// Records every call and keeps the values, like a registry hive.
    #[derive(Default)]
    struct FakeRegistry {
        values: RefCell<BTreeMap<(String, Option<String>), String>>,
        calls: RefCell<Vec<String>>,
    }

    impl Registry for FakeRegistry {
        fn set(&self, key: &str, name: Option<&str>, value: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!("set {key} {name:?}"));
            self.values.borrow_mut().insert((key.into(), name.map(Into::into)), value.into());
            Ok(())
        }
        fn get(&self, key: &str, name: Option<&str>) -> Option<String> {
            self.values.borrow().get(&(key.to_string(), name.map(Into::into))).cloned()
        }
        fn delete_value(&self, key: &str, name: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!("delete_value {key} {name}"));
            self.values.borrow_mut().remove(&(key.to_string(), Some(name.to_string())));
            Ok(())
        }
        fn delete_tree(&self, key: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!("delete_tree {key}"));
            self.values.borrow_mut().retain(|(k, _), _| k != key && !k.starts_with(&format!("{key}\\")));
            Ok(())
        }
    }

    /// A Velopack install layout on disk: `<tmp>\Hubbub\Update.exe` and `current\hubbub.exe`.
    fn installed() -> (tempfile::TempDir, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("Hubbub");
        std::fs::create_dir_all(root.join("current")).unwrap();
        std::fs::write(root.join("Update.exe"), b"").unwrap();
        let exe = root.join("current").join("hubbub.exe");
        std::fs::write(&exe, b"").unwrap();
        (tmp, exe)
    }

    fn dev_exe() -> PathBuf {
        PathBuf::from(r"C:\dev\hubbub\app\build\windows\x64\runner\Release\hubbub.exe")
    }

    #[test]
    fn layout_tells_an_install_from_a_dev_run() {
        let (_tmp, exe) = installed();
        assert_eq!(layout(&exe), Layout::Installed { root: exe.parent().unwrap().parent().unwrap().to_path_buf() });
        assert_eq!(layout(&dev_exe()), Layout::Dev);
        // A folder that merely happens to be called "current" is not an install.
        let tmp = tempfile::tempdir().unwrap();
        let lone = tmp.path().join("current").join("hubbub.exe");
        assert_eq!(layout(&lone), Layout::Dev);
    }

    #[test]
    fn launch_target_is_the_stable_path_when_installed_and_the_exe_when_not() {
        let (_tmp, exe) = installed();
        assert_eq!(launch_target(&exe), exe);
        assert_eq!(launch_target(&dev_exe()), dev_exe());
    }

    #[test]
    fn install_registers_the_protocol_and_turns_start_at_login_on() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        on_install(&reg, &exe).unwrap();
        let command = reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None).unwrap();
        assert_eq!(command, format!("\"{}\" \"%1\"", exe.display()));
        assert_eq!(reg.get(PROTOCOL_KEY, Some("URL Protocol")), Some(String::new()));
        assert_eq!(reg.get(RUN_KEY, Some(RUN_NAME)), Some(format!("\"{}\" --background", exe.display())));
        assert!(start_at_login(&reg));
    }

    #[test]
    fn the_toggle_writes_and_removes_the_run_value() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        set_start_at_login(&reg, &exe, true).unwrap();
        assert!(start_at_login(&reg));
        set_start_at_login(&reg, &exe, false).unwrap();
        assert!(!start_at_login(&reg));
        assert_eq!(
            *reg.calls.borrow(),
            [format!("set {RUN_KEY} Some(\"{RUN_NAME}\")"), format!("delete_value {RUN_KEY} {RUN_NAME}")]
        );
    }

    #[test]
    fn an_update_keeps_the_users_choice_of_start_at_login() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        on_install(&reg, &exe).unwrap();
        set_start_at_login(&reg, &exe, false).unwrap();
        on_update(&reg, &exe).unwrap();
        assert!(!start_at_login(&reg), "an update must not turn it back on");
        // ...and still repoints the link handler.
        assert!(reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None).is_some());
    }

    /// A stand-in server: `ping` copied to `<root>\current\livekit-server.exe`, running ~30 s.
    #[cfg(windows)]
    fn fake_server(dir: &Path) -> std::process::Child {
        std::fs::create_dir_all(dir).unwrap();
        let exe = dir.join("livekit-server.exe");
        std::fs::copy(r"C:\Windows\System32\PING.EXE", &exe).unwrap();
        std::process::Command::new(&exe).args(["-n", "30", "127.0.0.1"]).stdout(std::process::Stdio::null()).spawn().unwrap()
    }

    #[cfg(windows)]
    #[test]
    fn a_server_left_in_the_install_is_stopped_before_the_swap_and_a_foreign_one_is_not() {
        let tmp = tempfile::tempdir().unwrap();
        let mut ours = fake_server(&tmp.path().join("Hubbub").join("current"));
        let mut other = fake_server(&tmp.path().join("HubbubOther").join("current"));
        std::thread::sleep(std::time::Duration::from_millis(300));
        let killed = settle_install_servers(&tmp.path().join("Hubbub"), std::time::Duration::from_millis(300));
        assert_eq!(killed, 1);
        assert!(ours.try_wait().unwrap().is_some(), "the install's server should be gone");
        assert!(other.try_wait().unwrap().is_none(), "another copy's server must survive");
        other.kill().unwrap();
        // Nothing running: returns at once.
        assert_eq!(settle_install_servers(&tmp.path().join("Hubbub"), std::time::Duration::from_secs(5)), 0);
    }

    #[test]
    fn points_into_needs_the_whole_folder_name() {
        let root = PathBuf::from(r"C:\Users\a\AppData\Local\Hubbub");
        assert!(points_into(r#""C:\Users\a\AppData\Local\Hubbub\current\hubbub.exe" "%1""#, &root));
        assert!(points_into(r#""c:\users\a\appdata\local\HUBBUB\current\hubbub.exe""#, &root));
        assert!(!points_into(r#""C:\Users\a\AppData\Local\HubbubOther\current\hubbub.exe""#, &root));
    }

    #[test]
    fn a_dev_run_leaves_an_installed_copys_registrations_alone() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        on_install(&reg, &exe).unwrap();
        let before = reg.values.borrow().clone();
        register_on_launch(&reg, &dev_exe()).unwrap();
        set_start_at_login(&reg, &dev_exe(), true).unwrap();
        assert_eq!(*reg.values.borrow(), before);
        // The installed copy itself still refreshes them, and a dev run takes over once the
        // install is gone (its files no longer exist).
        register_on_launch(&reg, &exe).unwrap();
        std::fs::remove_file(exe.parent().unwrap().parent().unwrap().join("Update.exe")).unwrap();
        register_on_launch(&reg, &dev_exe()).unwrap();
        let command = reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None).unwrap();
        assert_eq!(command, format!("\"{}\" \"%1\"", dev_exe().display()));
    }

    #[test]
    fn quit_and_link_forward_launches_skip_the_registry() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(registers_on_launch(&args(&[])));
        assert!(registers_on_launch(&args(&["--background"])));
        assert!(!registers_on_launch(&args(&["--quit"])));
        assert!(!registers_on_launch(&args(&["hubbub://join/abc"])));
    }

    #[test]
    fn a_dev_run_registers_itself() {
        let reg = FakeRegistry::default();
        register_protocol(&reg, &dev_exe()).unwrap();
        let command = reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None).unwrap();
        assert_eq!(command, format!("\"{}\" \"%1\"", dev_exe().display()));
    }

    #[test]
    fn uninstall_removes_what_the_install_registered() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        on_install(&reg, &exe).unwrap();
        on_uninstall(&reg, &exe).unwrap();
        assert!(reg.values.borrow().is_empty(), "left behind: {:?}", reg.values.borrow());
    }

    #[test]
    fn uninstall_leaves_a_dev_runs_registration_alone() {
        let (_tmp, exe) = installed();
        let reg = FakeRegistry::default();
        on_install(&reg, &exe).unwrap();
        register_protocol(&reg, &dev_exe()).unwrap(); // a dev run took the link over since
        reg.set(RUN_KEY, Some(RUN_NAME), "\"D:\\other\\hubbub.exe\"").unwrap();
        on_uninstall(&reg, &exe).unwrap();
        assert!(reg.get(&format!(r"{PROTOCOL_KEY}\shell\open\command"), None).is_some());
        assert!(start_at_login(&reg));
    }
}
