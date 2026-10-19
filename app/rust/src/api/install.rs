//! The installer and self-update API for the Flutter side (Windows installs; other platforms
//! report "not installed" and do nothing). The hooks and registry rules are in `crate::install`.
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use velopack::{sources, UpdateInfo, UpdateManager};

/// The update `update_check` found, kept for `update_download`.
static CHECKED: Mutex<Option<UpdateInfo>> = Mutex::new(None);

/// An `http(s)` feed is a folder of static files (a GitHub release's `latest/download`); anything
/// else is a local folder, which is how an update is tried without a server. Fails when this is
/// not an installed copy.
fn manager_for(feed: &str) -> Result<UpdateManager> {
    Ok(if feed.starts_with("http://") || feed.starts_with("https://") {
        UpdateManager::new(sources::HttpSource::new(feed), None, None)?
    } else {
        UpdateManager::new(sources::FileSource::new(feed), None, None)?
    })
}

fn installed_manager() -> Result<UpdateManager> {
    Ok(UpdateManager::new(sources::NoneSource {}, None, None)?)
}

/// The installed version, or `None` for a copy that was not installed (a dev run).
#[frb(sync)]
pub fn install_version() -> Option<String> {
    installed_manager().ok().map(|m| m.get_current_version_as_string())
}

/// Whether Hubbub starts when the user logs in.
#[frb(sync)]
pub fn start_at_login() -> bool {
    #[cfg(windows)]
    {
        crate::install::start_at_login(&crate::install::WinRegistry)
    }
    #[cfg(not(windows))]
    false
}

#[frb(sync)]
pub fn set_start_at_login(on: bool) -> Result<()> {
    #[cfg(windows)]
    {
        crate::install::set_start_at_login(&crate::install::WinRegistry, &std::env::current_exe()?, on)
    }
    #[cfg(not(windows))]
    {
        let _ = on;
        Ok(())
    }
}

/// Looks for a newer release in `feed`. `Some(version)` when there is one. Errors (no network,
/// no feed yet, not installed) are for the caller to swallow.
pub async fn update_check(feed: String) -> Result<Option<String>> {
    let manager = manager_for(&feed)?;
    let found = manager.check_for_updates()?;
    let version = match found {
        velopack::UpdateCheck::UpdateAvailable(info) => {
            let v = info.TargetFullRelease.Version.clone();
            *CHECKED.lock().unwrap() = Some(*info);
            Some(v)
        }
        _ => None,
    };
    Ok(version)
}

/// Downloads what `update_check` found; returns its version. The files wait in the install
/// folder until `update_apply_on_exit` or the next start applies them.
pub async fn update_download(feed: String) -> Result<String> {
    let info = CHECKED.lock().unwrap().clone().ok_or_else(|| anyhow!("no update was checked for"))?;
    manager_for(&feed)?.download_updates(&info, None)?;
    Ok(info.TargetFullRelease.Version)
}

/// The version downloaded and waiting for a restart, if any.
#[frb(sync)]
pub fn update_pending() -> Option<String> {
    let asset = installed_manager().ok()?.get_update_pending_restart()?;
    Some(asset.Version)
}

/// Starts the updater, which waits for this process to exit, applies the downloaded update and
/// (if `restart`) launches the new version. The caller shuts the hub down and exits right after.
#[frb(sync)]
pub fn update_apply_on_exit(restart: bool) -> Result<()> {
    let manager = installed_manager()?;
    let asset = manager.get_update_pending_restart().ok_or_else(|| anyhow!("no downloaded update"))?;
    manager.wait_exit_then_apply_updates(&asset, true, restart, Vec::<String>::new())?;
    Ok(())
}
