//! Media host: runs a local LiveKit SFU and mints access tokens for members.
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context};
use livekit_api::access_token::{AccessToken, VideoGrants};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::ids::MemberId;

#[async_trait::async_trait]
pub trait MediaHost: Send + Sync {
    /// Starts the host; returns the 127.0.0.1 signal address.
    async fn start(&mut self, node_ip: IpAddr) -> anyhow::Result<SocketAddr>;
    async fn stop(&mut self);
    fn mint(&self, member: &MemberId, name: &str, room: &str) -> anyhow::Result<String>;
}

/// Media host for members that cannot host (phones): starting always fails, so
/// the election never settles on them.
pub struct NoMediaHost;

#[async_trait::async_trait]
impl MediaHost for NoMediaHost {
    async fn start(&mut self, _node_ip: IpAddr) -> anyhow::Result<SocketAddr> {
        bail!("this device cannot host media")
    }

    async fn stop(&mut self) {}

    fn mint(&self, _member: &MemberId, _name: &str, _room: &str) -> anyhow::Result<String> {
        bail!("this device cannot host media")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LkPorts {
    pub signal: u16,
    pub rtc_tcp: u16,
    pub rtc_udp: u16,
}

impl Default for LkPorts {
    fn default() -> Self {
        Self { signal: 7880, rtc_tcp: 7881, rtc_udp: 7882 }
    }
}

pub fn render_config(ports: &LkPorts, node_ip: IpAddr, api_key: &str, api_secret: &str) -> String {
    format!(
        "port: {}\n\
         bind_addresses: [\"127.0.0.1\"]\n\
         rtc:\n  tcp_port: {}\n  udp_port: {}\n  use_external_ip: false\n  node_ip: {}\n\
         keys:\n  {}: {}\n\
         logging:\n  level: info\n",
        ports.signal, ports.rtc_tcp, ports.rtc_udp, node_ip, api_key, api_secret
    )
}

const ALNUM: &[u8; 62] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Random alphanumeric string, unbiased via rejection sampling (accept bytes below 248 = 4 * 62).
fn random_alnum(len: usize) -> String {
    let mut out = String::with_capacity(len);
    let mut buf = [0u8; 64];
    while out.len() < len {
        getrandom::fill(&mut buf).expect("system randomness");
        for &b in &buf {
            if b < 248 && out.len() < len {
                out.push(ALNUM[(b % 62) as usize] as char);
            }
        }
    }
    out
}

pub struct LiveKitHost {
    bin: PathBuf,
    work_dir: PathBuf,
    ports: LkPorts,
    key: String,
    secret: String,
    child: Option<tokio::process::Child>,
}

impl LiveKitHost {
    fn child_exited(&mut self) -> bool {
        match self.child.as_mut() {
            Some(c) => !matches!(c.try_wait(), Ok(None)),
            None => true,
        }
    }

    pub fn new(bin: PathBuf, work_dir: PathBuf, ports: LkPorts) -> Self {
        Self {
            bin,
            work_dir,
            ports,
            key: format!("hb{}", random_alnum(14)),
            secret: random_alnum(43),
            child: None,
        }
    }

    /// The API key and secret this host's LiveKit server accepts (for `lk load-test`).
    pub fn api_credentials(&self) -> (&str, &str) {
        (&self.key, &self.secret)
    }
}

/// Minimal HTTP/1.1 `GET /`; true when the status line is 200.
async fn health_ok(addr: SocketAddr) -> bool {
    let attempt = async {
        let mut s = TcpStream::connect(addr).await.ok()?;
        s.write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").await.ok()?;
        let mut head = Vec::new();
        let mut buf = [0u8; 256];
        while !head.windows(2).any(|w| w == b"\r\n") {
            let n = s.read(&mut buf).await.ok()?;
            if n == 0 {
                break;
            }
            head.extend_from_slice(&buf[..n]);
        }
        let line = head.split(|&b| b == b'\r').next()?;
        Some(line.starts_with(b"HTTP/1.1 200") || line.starts_with(b"HTTP/1.0 200"))
    };
    matches!(tokio::time::timeout(Duration::from_secs(1), attempt).await, Ok(Some(true)))
}

/// Unix: livekit runs under this `/bin/sh` script and dies with its host. The host
/// holds the script's stdin; when that pipe reaches EOF (stop(), a drop, or the host
/// died, even by SIGKILL) a watcher sends livekit TERM, then KILL after a 2 s grace.
/// The script exits with livekit's status after reaping the watcher, so no helper
/// outlives both. A relaunched app couldn't reap an orphan itself: the App Sandbox
/// only lets it signal processes in its own sandbox instance.
/// `$1` is the binary and `$2` the config, passed as arguments, never spliced in.
/// The shell's own stderr (job notices) goes to /dev/null; livekit keeps the real one.
#[cfg(unix)]
const WRAPPER: &str = r#"exec 3<&0 </dev/null 4>&2 2>/dev/null
"$1" --config "$2" 2>&4 3<&- 4>&- &
p=$!
(
  exec 4>&-
  while read -r _ <&3; do :; done
  trap '' TERM
  kill -TERM "$p"
  i=0
  while [ "$i" -lt 20 ] && kill -0 "$p"; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$p"; then kill -KILL "$p"; fi
) &
r=$!
exec 3<&- 4>&-
wait "$p"
s=$?
kill "$r"
wait "$r"
exit "$s"
"#;

/// Spawns livekit with config `cfg`; on unix inside [`WRAPPER`], whose stdin pipe
/// the returned child holds.
fn spawn_server(bin: &std::path::Path, cfg: &std::path::Path) -> std::io::Result<tokio::process::Child> {
    #[cfg(unix)]
    let mut cmd = {
        let mut c = tokio::process::Command::new("/bin/sh");
        c.arg("-c").arg(WRAPPER).arg("sh").arg(bin).arg(cfg).stdin(std::process::Stdio::piped());
        c
    };
    #[cfg(windows)]
    let mut cmd = {
        let mut c = tokio::process::Command::new(bin);
        c.arg("--config").arg(cfg);
        c
    };
    cmd.kill_on_drop(true).spawn()
}

// Windows starts livekit directly, so a hard-killed app leaves it running; the next
// start reaps it through the pidfile. (Unix tests exercise the same logic with ps.)
#[cfg(windows)]
const SERVER_NAME: &str = "livekit-server.exe";

/// Executable name of process `pid`, or None when no such process exists.
#[cfg(any(windows, test))]
fn process_name(pid: u32) -> Option<String> {
    use std::process::Command;
    #[cfg(windows)]
    {
        let out = Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        let line = text.lines().find(|l| l.starts_with('"'))?;
        Some(line.trim_start_matches('"').split('"').next()?.to_string())
    }
    #[cfg(not(windows))]
    {
        let out = Command::new("ps").args(["-p", &pid.to_string(), "-o", "comm="]).output().ok()?;
        let comm = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if comm.is_empty() {
            return None;
        }
        // macOS prints the full path; Linux just the name.
        Some(comm.rsplit('/').next().unwrap_or(&comm).to_string())
    }
}

#[cfg(any(windows, test))]
fn kill_process(pid: u32, force: bool) {
    use std::process::{Command, Stdio};
    #[cfg(windows)]
    let mut cmd = {
        let _ = force;
        let mut c = Command::new("taskkill");
        c.args(["/F", "/PID", &pid.to_string()]);
        c
    };
    #[cfg(not(windows))]
    let mut cmd = {
        let mut c = Command::new("kill");
        c.args([if force { "-KILL" } else { "-TERM" }, &pid.to_string()]);
        c
    };
    let _ = cmd.stdout(Stdio::null()).stderr(Stdio::null()).status();
}

/// Kills a livekit server left behind by a crashed or SIGKILLed app (its pid is in
/// `pidfile`), then deletes the pidfile. The name check keeps a recycled pid safe.
#[cfg(any(windows, test))]
fn reap_stale(pidfile: &std::path::Path, expected_name: &str) {
    let Ok(text) = std::fs::read_to_string(pidfile) else { return };
    let _ = std::fs::remove_file(pidfile);
    let Ok(pid) = text.trim().parse::<u32>() else { return };
    if process_name(pid).as_deref() != Some(expected_name) {
        return;
    }
    kill_process(pid, false);
    for i in 0..40 {
        if process_name(pid).is_none() {
            return;
        }
        if i == 20 {
            kill_process(pid, true);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[async_trait::async_trait]
impl MediaHost for LiveKitHost {
    async fn start(&mut self, node_ip: IpAddr) -> anyhow::Result<SocketAddr> {
        if self.child.is_some() {
            bail!("livekit host already started");
        }
        std::fs::create_dir_all(&self.work_dir)
            .with_context(|| format!("creating {}", self.work_dir.display()))?;
        #[cfg(windows)]
        let pidfile = self.work_dir.join("livekit.pid");
        #[cfg(windows)]
        {
            let stale = pidfile.clone();
            tokio::task::spawn_blocking(move || reap_stale(&stale, SERVER_NAME)).await?;
        }
        let cfg = self.work_dir.join("livekit.yaml");
        std::fs::write(&cfg, render_config(&self.ports, node_ip, &self.key, &self.secret))
            .context("writing livekit.yaml")?;
        let child = spawn_server(&self.bin, &cfg).with_context(|| format!("spawning {}", self.bin.display()))?;
        #[cfg(windows)]
        if let Some(pid) = child.id() {
            let _ = std::fs::write(&pidfile, pid.to_string());
        }
        self.child = Some(child);

        let addr = SocketAddr::from(([127, 0, 0, 1], self.ports.signal));
        for _ in 0..100 {
            if self.child_exited() {
                self.stop().await;
                bail!("livekit exited during startup (port {} in use, or binary missing?)", self.ports.signal);
            }
            if health_ok(addr).await {
                // Something answered. If it was a foreign server, our own child hits the
                // bind error and exits shortly; only a living child makes it ours.
                tokio::time::sleep(Duration::from_millis(300)).await;
                if self.child_exited() {
                    self.stop().await;
                    bail!("livekit exited during startup; {addr} belongs to another process");
                }
                return Ok(addr);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        self.stop().await;
        bail!("livekit did not become healthy on {addr} within 5s")
    }

    async fn stop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        // Unix: EOF on the wrapper's stdin makes it stop livekit (TERM, then KILL after
        // the grace); the wrapper itself is killed only if that hangs.
        #[cfg(unix)]
        {
            drop(child.stdin.take());
            if matches!(tokio::time::timeout(Duration::from_secs(3), child.wait()).await, Ok(Ok(_))) {
                return;
            }
        }
        let _ = child.kill().await; // kill() also waits for exit
        // Only our own child's pidfile: a stop() before any start must leave a
        // stale one for the next start to reap.
        #[cfg(windows)]
        let _ = std::fs::remove_file(self.work_dir.join("livekit.pid"));
    }

    fn mint(&self, member: &MemberId, name: &str, room: &str) -> anyhow::Result<String> {
        let grants = VideoGrants {
            room_join: true,
            room: room.to_string(),
            can_publish: Some(true),
            can_subscribe: Some(true),
            can_publish_data: Some(true),
            ..Default::default()
        };
        AccessToken::with_api_key(&self.key, &self.secret)
            .with_identity(&member.to_string())
            .with_name(name)
            .with_grants(grants)
            .with_ttl(Duration::from_secs(6 * 3600))
            .to_jwt()
            .context("minting livekit token")
    }
}

#[cfg(any(test, feature = "test-util"))]
pub struct FakeHost {
    fail: bool,
    task: Option<tokio::task::JoinHandle<()>>,
}

#[cfg(any(test, feature = "test-util"))]
impl FakeHost {
    pub fn new() -> Self {
        Self { fail: false, task: None }
    }
    pub fn failing() -> Self {
        Self { fail: true, task: None }
    }
}

#[cfg(any(test, feature = "test-util"))]
impl Default for FakeHost {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(any(test, feature = "test-util"))]
#[async_trait::async_trait]
impl MediaHost for FakeHost {
    async fn start(&mut self, _node_ip: IpAddr) -> anyhow::Result<SocketAddr> {
        if self.fail {
            bail!("fake host configured to fail");
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        self.task = Some(tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = s.split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                });
            }
        }));
        Ok(addr)
    }

    async fn stop(&mut self) {
        if let Some(t) = self.task.take() {
            t.abort();
        }
    }

    fn mint(&self, member: &MemberId, _name: &str, room: &str) -> anyhow::Result<String> {
        Ok(format!("fake:{member}:{room}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn m(n: u8) -> MemberId {
        MemberId([n; 32])
    }

    fn decode_unverified(jwt: &str) -> serde_json::Value {
        let payload = jwt.split('.').nth(1).expect("jwt payload");
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[cfg(unix)]
    fn spawn_orphan_sleep() -> u32 {
        // Double fork so the sleeper is reparented to init and reaped when killed.
        let out = std::process::Command::new("sh")
            .args(["-c", "sleep 60 >/dev/null 2>&1 & echo $!"])
            .output()
            .unwrap();
        let pid = String::from_utf8_lossy(&out.stdout).trim().parse().unwrap();
        // $! is the fork, which may not have exec'd sleep yet.
        for _ in 0..100 {
            if process_name(pid).as_deref() == Some("sleep") {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        pid
    }

    #[cfg(unix)]
    #[test]
    fn reap_stale_kills_matching_process_and_removes_pidfile() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("livekit.pid");
        let pid = spawn_orphan_sleep();
        std::fs::write(&pidfile, pid.to_string()).unwrap();
        assert_eq!(process_name(pid).as_deref(), Some("sleep"));
        reap_stale(&pidfile, "sleep");
        assert!(process_name(pid).is_none(), "stale process still alive");
        assert!(!pidfile.exists());
    }

    #[cfg(unix)]
    #[test]
    fn reap_stale_spares_a_process_with_another_name() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("livekit.pid");
        let pid = spawn_orphan_sleep();
        std::fs::write(&pidfile, pid.to_string()).unwrap();
        reap_stale(&pidfile, "livekit-server");
        assert_eq!(process_name(pid).as_deref(), Some("sleep"));
        assert!(!pidfile.exists());
        kill_process(pid, true);
    }

    #[cfg(unix)]
    fn script(dir: &std::path::Path, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let p = dir.join("fake livekit");
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    /// A stand-in server under "<tmp>/Application Support/" (spaces, like the app's
    /// data dir) that writes its pid to `<cfg>.pid`, then runs `body`.
    /// Returns (tmp guard, that dir, bin, cfg).
    #[cfg(unix)]
    fn stand_in(body: &str) -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Application Support");
        std::fs::create_dir(&dir).unwrap();
        let bin = script(&dir, &format!("echo $$ > \"$2.pid\"\n{body}"));
        let cfg = dir.join("livekit.yaml");
        (tmp, dir, bin, cfg)
    }

    #[cfg(unix)]
    async fn stand_in_pid(cfg: &std::path::Path) -> u32 {
        let f = PathBuf::from(format!("{}.pid", cfg.display()));
        for _ in 0..100 {
            if let Some(pid) = std::fs::read_to_string(&f).ok().and_then(|t| t.trim().parse().ok()) {
                return pid;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("stand-in never started");
    }

    #[cfg(unix)]
    fn alive(pid: u32) -> bool {
        std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    /// Pids of live processes whose command line mentions `dir`: the wrapper and its
    /// watcher (their arguments name the binary and config), or a real livekit.
    #[cfg(unix)]
    fn mentioning(dir: &std::path::Path) -> String {
        let out = std::process::Command::new("pgrep").arg("-f").arg(dir).output().unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    #[cfg(unix)]
    async fn within(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
        let end = std::time::Instant::now() + limit;
        while !done() {
            if std::time::Instant::now() > end {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        true
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn wrapped_server_dies_when_the_host_closes_its_stdin() {
        let (_tmp, dir, bin, cfg) = stand_in("exec sleep 30");
        let mut child = spawn_server(&bin, &cfg).unwrap();
        let pid = stand_in_pid(&cfg).await;
        assert!(alive(pid));
        drop(child.stdin.take());
        assert!(within(Duration::from_millis(1500), || !alive(pid)).await, "stand-in survived EOF");
        let status = tokio::time::timeout(Duration::from_secs(2), child.wait()).await.unwrap().unwrap();
        assert_eq!(status.code(), Some(128 + 15), "wrapper exits with the server's TERM status");
        assert_eq!(mentioning(&dir), "", "a helper outlived the server");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn dropping_the_child_also_ends_the_server() {
        let (_tmp, dir, bin, cfg) = stand_in("exec sleep 30");
        let child = spawn_server(&bin, &cfg).unwrap();
        let pid = stand_in_pid(&cfg).await;
        drop(child); // kill_on_drop SIGKILLs the wrapper, and its stdin pipe closes
        assert!(within(Duration::from_millis(1500), || !alive(pid)).await, "stand-in survived the drop");
        assert!(within(Duration::from_millis(1500), || mentioning(&dir).is_empty()).await, "helper left behind");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn wrapper_exits_with_the_server_and_leaves_no_watcher() {
        let (_tmp, dir, bin, cfg) = stand_in("sleep 0.2\nexit 3");
        let mut child = spawn_server(&bin, &cfg).unwrap();
        let stdin = child.stdin.take(); // the host lives on: its end of the pipe stays open
        let status = tokio::time::timeout(Duration::from_secs(2), child.wait()).await.unwrap().unwrap();
        assert_eq!(status.code(), Some(3));
        assert_eq!(mentioning(&dir), "", "the watcher outlived the server");
        drop(stdin);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stop_ends_the_wrapped_server() {
        let (_tmp, dir, bin, cfg) = stand_in("exec sleep 30");
        let mut host = LiveKitHost::new(bin.clone(), dir.clone(), LkPorts::default());
        host.child = Some(spawn_server(&bin, &cfg).unwrap());
        let pid = stand_in_pid(&cfg).await;
        let t = std::time::Instant::now();
        host.stop().await;
        assert!(t.elapsed() < Duration::from_secs(1), "stop took {:?}", t.elapsed());
        assert!(!alive(pid));
        assert_eq!(mentioning(&dir), "");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stop_kills_a_server_that_ignores_term_after_the_grace() {
        let (_tmp, dir, bin, cfg) = stand_in("trap '' TERM\nexec sleep 30");
        let mut host = LiveKitHost::new(bin.clone(), dir.clone(), LkPorts::default());
        host.child = Some(spawn_server(&bin, &cfg).unwrap());
        let pid = stand_in_pid(&cfg).await;
        let t = std::time::Instant::now();
        host.stop().await;
        // The wrapper's KILL lands after its 2 s grace, before stop's own 3 s fallback.
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(1900) && took < Duration::from_millis(2900), "stop took {took:?}");
        assert!(!alive(pid));
        assert_eq!(mentioning(&dir), "");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn start_fails_when_child_exits_even_if_a_foreign_server_answers() {
        let dir = tempfile::tempdir().unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buf = [0u8; 512];
                    let _ = s.read(&mut buf).await;
                    let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await;
                });
            }
        });
        let bin = script(dir.path(), "exit 1");
        let ports = LkPorts { signal: port, ..LkPorts::default() };
        let mut host = LiveKitHost::new(bin, dir.path().to_path_buf(), ports);
        let r = host.start("127.0.0.1".parse().unwrap()).await;
        assert!(r.is_err(), "start must not trust a foreign server on the port");
    }

    /// The work dir may not exist yet (a fresh hub root): `start` creates it before
    /// writing the config. The binary is missing, so start fails at spawn, after the write.
    #[tokio::test]
    async fn start_creates_a_missing_work_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let work = tmp.path().join("not").join("yet");
        let mut host = LiveKitHost::new(tmp.path().join("no-such-livekit"), work.clone(), LkPorts::default());
        let err = host.start("127.0.0.1".parse().unwrap()).await.unwrap_err();
        assert!(format!("{err:#}").contains("spawning"), "unexpected failure: {err:#}");
        assert!(work.join("livekit.yaml").exists(), "config not written into the created dir");
    }

    #[tokio::test]
    async fn stop_without_a_child_keeps_a_stale_pidfile_for_the_next_start() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("livekit.pid");
        std::fs::write(&pidfile, "999999").unwrap();
        let mut host = LiveKitHost::new(PathBuf::from("unused"), dir.path().to_path_buf(), LkPorts::default());
        host.stop().await;
        assert!(pidfile.exists(), "a start-less stop must not delete the stale pidfile");
    }

    /// Not a test on its own: the host process the SIGKILL tests start (this test
    /// binary again, with HUBBUB_TEST_HOST set). Runs a wrapped server, prints "ready",
    /// and waits to be killed. With HUBBUB_TEST_PORT it runs a real `start()`.
    #[cfg(unix)]
    #[tokio::test]
    #[ignore = "helper process for the host SIGKILL tests"]
    async fn host_process() {
        let Ok(dir) = std::env::var("HUBBUB_TEST_HOST") else { return };
        let (dir, bin) = (PathBuf::from(dir), PathBuf::from(std::env::var("HUBBUB_TEST_BIN").unwrap()));
        let mut host = match std::env::var("HUBBUB_TEST_PORT") {
            Ok(port) => {
                let signal: u16 = port.parse().unwrap();
                let ports = LkPorts { signal, rtc_tcp: signal + 1, rtc_udp: signal + 2 };
                let mut host = LiveKitHost::new(bin, dir, ports);
                host.start("127.0.0.1".parse().unwrap()).await.unwrap();
                host
            }
            Err(_) => {
                let mut host = LiveKitHost::new(bin.clone(), dir.clone(), LkPorts::default());
                host.child = Some(spawn_server(&bin, &dir.join("livekit.yaml")).unwrap());
                host
            }
        };
        println!("ready");
        tokio::time::sleep(Duration::from_secs(30)).await; // SIGKILLed long before this
        host.stop().await;
    }

    /// Runs `host_process` (under `sandbox-exec -p <sandbox>` when given), SIGKILLs it
    /// once its server runs, and expects nothing mentioning `dir` to survive `limit`.
    /// `stand_in`: the server is a `stand_in()` script, so its pid is known too.
    #[cfg(unix)]
    async fn sigkill_host(bin: &std::path::Path, dir: &std::path::Path, port: Option<u16>, sandbox: Option<&str>, limit: Duration) {
        use std::io::BufRead;
        let exe = std::env::current_exe().unwrap();
        let mut cmd = match sandbox {
            Some(profile) => {
                let mut c = std::process::Command::new("sandbox-exec");
                c.arg("-p").arg(profile).arg(&exe);
                c
            }
            None => std::process::Command::new(&exe),
        };
        cmd.args(["--exact", "media_host::tests::host_process", "--ignored", "--nocapture", "--test-threads=1"])
            .env("HUBBUB_TEST_HOST", dir)
            .env("HUBBUB_TEST_BIN", bin)
            .stdout(std::process::Stdio::piped());
        if let Some(port) = port {
            cmd.env("HUBBUB_TEST_PORT", port.to_string());
        }
        let mut host = cmd.spawn().unwrap();
        let mut lines = std::io::BufReader::new(host.stdout.take().unwrap()).lines();
        assert!(lines.any(|l| l.is_ok_and(|l| l.ends_with("ready"))), "host process quit before its server ran");
        // Keep draining: the server shares this stdout, and a closed pipe would kill it.
        std::thread::spawn(move || lines.for_each(drop));
        let server = match port {
            None => Some(stand_in_pid(&dir.join("livekit.yaml")).await),
            Some(_) => None,
        };
        assert_ne!(mentioning(dir), "", "server not running");
        host.kill().unwrap(); // SIGKILL: no stop() or destructor runs in the host
        host.wait().unwrap();
        let gone = within(limit, || mentioning(dir).is_empty() && server.is_none_or(|p| !alive(p))).await;
        assert!(gone, "left behind: {} (server {server:?})", mentioning(dir));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn host_sigkill_ends_its_wrapped_server() {
        let (_tmp, dir, bin, _cfg) = stand_in("exec sleep 30");
        sigkill_host(&bin, &dir, None, None, Duration::from_millis(1500)).await;
    }

    /// The App Sandbox's process rules (application.sb, appsandbox-common.sb) over
    /// allow-default: no process list, no sysmond, signals only inside this sandbox.
    #[cfg(target_os = "macos")]
    const APP_SANDBOX_PROCESS_RULES: &str = r#"(version 1)(allow default)
        (deny process-info*)(allow process-info-pidinfo)
        (allow process-info-pidfdinfo process-info-pidfileportinfo process-info-setcontrol
               process-info-dirtycontrol process-info-rusage process-info-ledger (target self))
        (allow process-codesigning-status* (target self))
        (deny mach-lookup (global-name "com.apple.sysmond"))
        (deny signal)(allow signal (target same-sandbox))"#;

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn host_sigkill_ends_its_wrapped_server_under_app_sandbox_rules() {
        let (_tmp, dir, bin, _cfg) = stand_in("exec sleep 30");
        sigkill_host(&bin, &dir, None, Some(APP_SANDBOX_PROCESS_RULES), Duration::from_millis(1500)).await;
    }

    /// Needs the real binary: `cargo test -p hubbub-core --lib real_livekit -- --ignored`
    /// (macOS arm64 vendor binary). SIGKILL of a host (as of a CLI node or the app)
    /// must not leave a livekit-server behind, unsandboxed or under the sandbox rules.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore]
    async fn real_livekit_dies_when_its_host_is_sigkilled() {
        let bin = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vendor/livekit/darwin-arm64/livekit-server");
        for sandbox in [None, Some(APP_SANDBOX_PROCESS_RULES)] {
            let dir = tempfile::tempdir().unwrap();
            sigkill_host(&bin, dir.path(), Some(17880), sandbox, Duration::from_secs(3)).await;
        }
    }

    #[tokio::test]
    async fn no_media_host_never_starts_or_mints() {
        let mut h = NoMediaHost;
        assert!(h.start("127.0.0.1".parse().unwrap()).await.is_err());
        assert!(h.mint(&m(1), "a", "lobby").is_err());
        h.stop().await;
    }

    #[test]
    fn render_config_pins_localhost_signal_and_single_udp_port() {
        let y = render_config(&LkPorts::default(), "192.168.1.20".parse().unwrap(), "hbK", "S");
        assert!(y.contains("bind_addresses: [\"127.0.0.1\"]"));
        assert!(y.contains("udp_port: 7882"));
        assert!(y.contains("node_ip: 192.168.1.20"));
        assert!(y.contains("use_external_ip: false"));
    }

    #[test]
    fn minted_token_has_identity_room_and_grants() {
        let h = LiveKitHost::new("x".into(), std::env::temp_dir(), LkPorts::default());
        let t = h.mint(&m(1), "mini", "lobby").unwrap();
        let claims = decode_unverified(&t);
        assert_eq!(claims["sub"], m(1).to_string());
        assert_eq!(claims["video"]["room"], "lobby");
        assert_eq!(claims["video"]["roomJoin"], true);
        assert_eq!(claims["video"]["canPublish"], true);
        assert_eq!(claims["video"]["canSubscribe"], true);
        assert_eq!(claims["video"]["canPublishData"], true);
        assert_eq!(claims["name"], "mini");
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let left = claims["exp"].as_i64().unwrap() - now;
        assert!((6 * 3600 - 60..=6 * 3600 + 60).contains(&left), "ttl left {left}");
    }

    #[test]
    fn key_and_secret_formats() {
        let h = LiveKitHost::new("x".into(), std::env::temp_dir(), LkPorts::default());
        assert_eq!(h.key.len(), 16);
        assert!(h.key.starts_with("hb"));
        assert_eq!(h.secret.len(), 43);
        assert!(h.key.chars().chain(h.secret.chars()).all(|c| c.is_ascii_alphanumeric()));
        let h2 = LiveKitHost::new("x".into(), std::env::temp_dir(), LkPorts::default());
        assert_ne!(h.secret, h2.secret);
    }

    #[tokio::test]
    async fn fake_host_echoes_and_mints() {
        let mut f = FakeHost::new();
        let addr = f.start("127.0.0.1".parse().unwrap()).await.unwrap();
        let mut s = TcpStream::connect(addr).await.unwrap();
        s.write_all(b"hi").await.unwrap();
        let mut b = [0u8; 2];
        s.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"hi");
        assert_eq!(f.mint(&m(1), "n", "r").unwrap(), format!("fake:{}:r", m(1)));
        f.stop().await;
        assert!(FakeHost::failing().start("127.0.0.1".parse().unwrap()).await.is_err());
    }

    #[tokio::test]
    #[ignore = "needs LIVEKIT_BIN"]
    async fn livekit_starts_and_signal_is_localhost_only() {
        let bin = std::env::var("LIVEKIT_BIN").expect("LIVEKIT_BIN");
        // Local LAN address: connected UDP socket sends nothing.
        let probe = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
        probe.connect("192.0.2.1:9").unwrap();
        let lan = probe.local_addr().unwrap().ip();
        let dir = tempfile::tempdir().unwrap();
        let mut h = LiveKitHost::new(bin.into(), dir.path().to_path_buf(), LkPorts::default());
        let started = h.start(lan).await;

        let mut health = None;
        let mut lan_connect = None;
        let mut lsof = String::new();
        if let Ok(addr) = &started {
            health = Some(health_ok(*addr).await);
            lan_connect = Some(
                tokio::time::timeout(Duration::from_secs(2), TcpStream::connect(SocketAddr::new(lan, 7880)))
                    .await
                    .map(|r| r.is_ok())
                    .unwrap_or(false),
            );
            lsof = String::from_utf8_lossy(
                &std::process::Command::new("lsof").args(["-nP", "-iUDP:7882"]).output().unwrap().stdout,
            )
            .into_owned();
            println!("lan ip: {lan}\nhealth: {health:?}\nlan connect succeeded: {lan_connect:?}\n{lsof}");
        }
        h.stop().await;

        started.unwrap();
        assert_eq!(health, Some(true));
        assert_eq!(lan_connect, Some(false), "SECURITY: signal reachable on LAN");
        assert!(lsof.contains("7882"), "UDP 7882 not bound: {lsof}");
    }
}
