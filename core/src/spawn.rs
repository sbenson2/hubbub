//! Starting other programs without a console window.
//!
//! hubbub.exe is a GUI program with no console, so on Windows each console program it starts
//! (livekit-server, tasklist, taskkill) gets a console window of its own. livekit-server's stayed
//! open for as long as this node hosted, and a friend saw it appear over a full-screen game after
//! a host handover. Build every `Command` with [`command`]; tokio's comes from it through `From`.

use std::ffi::OsStr;

/// A `Command` for `program` that opens no console window on Windows. Its stdio is still the
/// parent's unless set otherwise, so a hubbub run from a terminal keeps the child's output.
pub fn command(program: impl AsRef<OsStr>) -> std::process::Command {
    #[cfg_attr(not(windows), allow(unused_mut))]
    let mut c = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// A console program started through `command` gets a hidden console of its own: not a new
    /// window (what it got from the windowless GUI app) and not a share of the test's console.
    #[cfg(windows)]
    #[test]
    fn a_console_program_gets_a_hidden_console_of_its_own() {
        // [char]34 is the C# string's double quote; one on the command line would need escaping.
        let script = "$q = [char]34; $k = Add-Type -Name W -Namespace HubbubSpawnTest -PassThru -MemberDefinition \
                      ('[DllImport(' + $q + 'kernel32.dll' + $q + ')] public static extern System.IntPtr GetConsoleWindow();' + \
                      '[DllImport(' + $q + 'kernel32.dll' + $q + ')] public static extern uint GetConsoleProcessList(uint[] l, uint n);'); \
                      '{0} {1}' -f $k::GetConsoleProcessList((New-Object uint32[] 16), 16), $k::GetConsoleWindow()";
        let out = command("powershell").args(["-NoProfile", "-NonInteractive", "-Command", script]).output().unwrap();
        assert!(out.status.success(), "powershell failed: {}", String::from_utf8_lossy(&out.stderr));
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "1 0", "(processes on the console, its window)");
    }

    /// Code that runs inside hubbub.exe builds no `Command` except through [`command`].
    #[test]
    fn every_spawn_goes_through_command() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut files = Vec::new();
        for dir in [root.join("src"), root.join("../app/rust/src")] {
            rust_files(&dir, &mut files);
        }
        let mut offenders = Vec::new();
        for file in files.iter().filter(|f| !f.ends_with("spawn.rs")) {
            let src = std::fs::read_to_string(file).unwrap();
            for (n, line) in without_test_modules(&src) {
                if line.contains("Command::new(") {
                    offenders.push(format!("{}:{n}: {}", file.display(), line.trim()));
                }
            }
        }
        assert!(offenders.is_empty(), "use crate::spawn::command instead:\n{}", offenders.join("\n"));
    }

    fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }

    /// The numbered lines of `src` outside its `#[cfg(test)] mod ... { ... }` blocks (brace-counted).
    fn without_test_modules(src: &str) -> Vec<(usize, &str)> {
        let mut kept = Vec::new();
        let mut lines = src.lines().enumerate().peekable();
        while let Some((i, line)) = lines.next() {
            let opens_test_mod = line.trim() == "#[cfg(test)]"
                && lines.peek().is_some_and(|(_, next)| next.trim_start().starts_with("mod ") && next.trim_end().ends_with('{'));
            if !opens_test_mod {
                kept.push((i + 1, line));
                continue;
            }
            let mut depth = 0i32;
            for (_, line) in lines.by_ref() {
                depth += line.matches('{').count() as i32 - line.matches('}').count() as i32;
                if depth <= 0 {
                    break;
                }
            }
        }
        kept
    }
}
