use std::path::PathBuf;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use hubbub_core::hub::{Hub, HubConfig};
use hubbub_core::ids::CommunityId;
use hubbub_core::join::JoinEvent;
use hubbub_core::net::RelayChoice;
use hubbub_core::node::Node;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(name = "hubbub", about = "Hubbub command-line client: servers, invites and chat from a terminal")]
struct Cli {
    /// The folder holding this device's identity and servers. Required on Windows; elsewhere it
    /// defaults to `$HOME/.hubbub`. Only one process may have a root open at a time.
    #[arg(long, global = true)]
    root: Option<PathBuf>,
    /// LiveKit server binary: when given, this device may host media (and servers it creates or
    /// joins record it as able to). Text-only otherwise, and then no host is ever elected.
    #[arg(long, global = true)]
    livekit_bin: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print this device's member id and tag.
    Id,
    /// Show or set this device's profile name.
    Profile {
        #[command(subcommand)]
        cmd: ProfileCmd,
    },
    /// Create or list servers.
    Community {
        #[command(subcommand)]
        cmd: CommunityCmd,
    },
    /// Print an invite link to a server.
    Invite {
        /// The server's id, from `community list`.
        cid: String,
        /// Hours the link stays valid; 0 means never.
        #[arg(long, default_value_t = 24)]
        hours: u32,
        /// How many members may join with it; 0 means unlimited.
        #[arg(long, default_value_t = 0)]
        uses: u8,
    },
    /// Join the server an invite link is for; prints its id. Needs a member online.
    Join { link: String },
    /// Run this device's servers, printing each event as a JSON line.
    /// Each stdin line `#<channel> <text>` sends a text message.
    Run {
        /// The server stdin messages go to; needed only with more than one server.
        #[arg(long)]
        community: Option<String>,
    },
}

#[derive(Subcommand)]
enum ProfileCmd {
    /// Set the name this device uses in servers it creates or joins.
    Name {
        /// The new name; omit to print the current one.
        name: Option<String>,
    },
}

#[derive(Subcommand)]
enum CommunityCmd {
    /// Create a server owned by this device; prints its id.
    New { name: String },
    /// List this device's servers as `<id> <name>`.
    List,
}

/// The root to open: `--root`, else `$HOME/.hubbub` (never guessed on Windows).
fn resolve_root(root: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(r) = root {
        return Ok(r);
    }
    if cfg!(windows) {
        bail!("--root <dir> is required on Windows");
    }
    let home = std::env::var_os("HOME").context("HOME is not set; pass --root")?;
    Ok(PathBuf::from(home).join(".hubbub"))
}

fn parse_cid(s: &str) -> Result<CommunityId> {
    s.parse().map_err(|e| anyhow!("{s:?} is not a server id: {e}"))
}

async fn open_hub(root: PathBuf, livekit_bin: Option<PathBuf>) -> Result<Hub> {
    let cfg = HubConfig { can_host: livekit_bin.is_some(), relay: RelayChoice::N0Default, livekit_bin };
    Hub::open(&root, cfg).await.with_context(|| format!("opening {}", root.display()))
}

fn node_of(hub: &Hub, cid: &CommunityId) -> Result<std::sync::Arc<Node>> {
    hub.node(cid).ok_or_else(|| anyhow!("no server {cid} on this device (see `community list`)"))
}

async fn run_cmd(cmd: Cmd, root: PathBuf, livekit_bin: Option<PathBuf>) -> Result<()> {
    match cmd {
        Cmd::Run { community } => return run_hub(root, community, livekit_bin).await,
        Cmd::Id => {
            let hub = open_hub(root, livekit_bin).await?;
            let id = hub.member_id();
            println!("{} {}", id, id.tag());
            hub.shutdown().await;
        }
        Cmd::Profile { cmd: ProfileCmd::Name { name } } => {
            let hub = open_hub(root, livekit_bin).await?;
            match name {
                Some(n) => hub.set_profile_name(&n)?,
                None => println!("{}", hub.profile_name()),
            }
            hub.shutdown().await;
        }
        Cmd::Community { cmd: CommunityCmd::New { name } } => {
            let hub = open_hub(root, livekit_bin).await?;
            let cid = hub.create_community(&name).await?;
            println!("{cid}");
            hub.shutdown().await;
        }
        Cmd::Community { cmd: CommunityCmd::List } => {
            let hub = open_hub(root, livekit_bin).await?;
            for (cid, name) in hub.communities() {
                println!("{cid} {name}");
            }
            hub.shutdown().await;
        }
        Cmd::Invite { cid, hours, uses } => {
            let cid = parse_cid(&cid)?;
            let hub = open_hub(root, livekit_bin).await?;
            let link = node_of(&hub, &cid).map(|n| n.invite_create(hours.saturating_mul(60), uses));
            hub.shutdown().await;
            println!("{}", link?);
        }
        Cmd::Join { link } => {
            let hub = open_hub(root, livekit_bin).await?;
            let (tx, mut rx) = mpsc::unbounded_channel();
            let report = tokio::spawn(async move {
                while let Some(ev) = rx.recv().await {
                    match ev {
                        JoinEvent::Trying => eprintln!("hubbub: dialing the invite's members..."),
                        JoinEvent::Offline => eprintln!("hubbub: nobody answered; trying again (Ctrl-C to stop)"),
                        JoinEvent::Denied(d) => eprintln!("hubbub: refused: {d}"),
                        JoinEvent::Joined(_) => {}
                    }
                }
            });
            let joined = tokio::select! {
                r = hub.join(&link, tx) => r,
                _ = tokio::signal::ctrl_c() => Err(anyhow!("cancelled")),
            };
            report.abort();
            hub.shutdown().await;
            println!("{}", joined?);
        }
    }
    Ok(())
}

async fn run_hub(root: PathBuf, community: Option<String>, livekit_bin: Option<PathBuf>) -> Result<()> {
    let hub = open_hub(root, livekit_bin).await?;
    let all = hub.communities();
    let target = match community {
        Some(c) => Some(parse_cid(&c)?),
        None if all.len() == 1 => Some(all[0].0),
        None => None,
    };
    let (tx, mut events) = mpsc::unbounded_channel::<String>();
    for (cid, name) in &all {
        let node = node_of(&hub, cid)?;
        let mut sub = node.subscribe();
        let (tx, cid) = (tx.clone(), *cid);
        tokio::spawn(async move {
            loop {
                match sub.recv().await {
                    Ok(ev) => {
                        let mut v = serde_json::to_value(&ev).unwrap_or_default();
                        v["community"] = serde_json::Value::String(cid.to_string());
                        if tx.send(v.to_string()).is_err() {
                            return;
                        }
                    }
                    Err(RecvError::Lagged(n)) => eprintln!("hubbub: {n} events dropped for {cid}"),
                    Err(RecvError::Closed) => return,
                }
            }
        });
        eprintln!("hubbub: running {cid} {name}");
    }
    drop(tx);
    match &target {
        Some(cid) => eprintln!("hubbub: type `#general hello` to send to {cid}; Ctrl-C to leave"),
        None => eprintln!("hubbub: {} servers; pass --community <id> to send messages", all.len()),
    }
    let mut stdin = stdin_lines();
    let mut stdin_open = true;
    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);
    loop {
        tokio::select! {
            _ = &mut ctrl_c => break,
            line = stdin.recv(), if stdin_open => match line {
                Some(line) => match target.as_ref().and_then(|c| hub.node(c)) {
                    Some(node) => send_line(&node, &line).await,
                    None => eprintln!("hubbub: no server to send to; pass --community <id>"),
                },
                // EOF, as when run with no terminal: keep running without input.
                None => stdin_open = false,
            },
            ev = events.recv() => match ev {
                Some(line) => println!("{line}"),
                None => break,
            },
        }
    }
    eprintln!("hubbub: leaving");
    hub.shutdown().await;
    Ok(())
}

/// Stdin lines, read on a thread of its own so a read waiting on the terminal never holds up exit.
fn stdin_lines() -> mpsc::UnboundedReceiver<String> {
    let (tx, rx) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lines() {
            let Ok(line) = line else { return };
            if tx.send(line).is_err() {
                return;
            }
        }
    });
    rx
}

/// `#<channel> <text>` as (channel, text).
fn parse_text_line(line: &str) -> Option<(&str, &str)> {
    line.strip_prefix('#')?.split_once(' ')
}

async fn send_line(node: &Node, line: &str) {
    if line.trim().is_empty() {
        return;
    }
    let Some((channel, body)) = parse_text_line(line) else {
        eprintln!("hubbub: to send a message, type #<channel> <text>");
        return;
    };
    match node.send_text(channel, body).await {
        Ok(_) if node.host_state().host.is_none() => {
            eprintln!("hubbub: no host yet; the message goes out when one appears")
        }
        Ok(_) => {}
        Err(e) => eprintln!("hubbub: message not sent: {e:#}"),
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = resolve_root(cli.root)?;
    tokio::runtime::Runtime::new()?.block_on(run_cmd(cli.cmd, root, cli.livekit_bin))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(std::iter::once("hubbub").chain(args.iter().copied())).unwrap()
    }

    #[test]
    fn text_lines_name_a_channel_then_the_message() {
        assert_eq!(parse_text_line("#general hello there"), Some(("general", "hello there")));
        assert_eq!(parse_text_line("#off-topic  two spaces"), Some(("off-topic", " two spaces")));
        assert_eq!(parse_text_line("#general"), None);
        assert_eq!(parse_text_line("general hello"), None);
    }

    #[test]
    fn commands_parse_with_root_anywhere() {
        let c = parse(&["--root", "r", "community", "new", "Lab"]);
        assert_eq!(c.root, Some(PathBuf::from("r")));
        assert!(matches!(c.cmd, Cmd::Community { cmd: CommunityCmd::New { ref name } } if name == "Lab"));
        let c = parse(&["community", "list", "--root", "r"]);
        assert!(matches!(c.cmd, Cmd::Community { cmd: CommunityCmd::List }));
        let c = parse(&["profile", "name", "Ann"]);
        assert!(matches!(c.cmd, Cmd::Profile { cmd: ProfileCmd::Name { name: Some(ref n) } } if n == "Ann"));
        let c = parse(&["join", "hubbub://x"]);
        assert!(matches!(c.cmd, Cmd::Join { ref link } if link == "hubbub://x"));
    }

    #[test]
    fn invite_defaults_and_options() {
        let c = parse(&["invite", "abc"]);
        assert!(matches!(c.cmd, Cmd::Invite { ref cid, hours: 24, uses: 0 } if cid == "abc"));
        let c = parse(&["invite", "abc", "--hours", "2", "--uses", "5"]);
        assert!(matches!(c.cmd, Cmd::Invite { hours: 2, uses: 5, .. }));
        assert!(Cli::try_parse_from(["hubbub", "invite", "abc", "--uses", "300"]).is_err());
    }

    #[test]
    fn run_takes_optional_community_and_global_livekit() {
        let c = parse(&["run"]);
        assert!(matches!(c.cmd, Cmd::Run { community: None }));
        let c = parse(&["run", "--community", "abc", "--livekit-bin", "lk"]);
        assert!(matches!(c.cmd, Cmd::Run { community: Some(_) }));
        assert_eq!(c.livekit_bin, Some(PathBuf::from("lk")));
    }

    #[test]
    fn root_is_explicit_or_defaulted_off_windows() {
        assert_eq!(resolve_root(Some(PathBuf::from("x"))).unwrap(), PathBuf::from("x"));
        if cfg!(windows) {
            assert!(resolve_root(None).is_err());
        }
    }
}
