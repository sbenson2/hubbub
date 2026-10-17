use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use hubbub_core::community::{CommunityFile, MemberEntry};
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::{LiveKitHost, LkPorts};
use hubbub_core::net::RelayChoice;
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(name = "hubbub", about = "Hubbub spike CLI")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print this node's member id and tag.
    Id {
        #[arg(long)]
        data_dir: Option<PathBuf>,
    },
    /// Community file operations.
    Community {
        #[command(subcommand)]
        cmd: CommunityCmd,
    },
    /// Run a node: join the community, elect a host, print each event as a JSON line.
    /// Each stdin line `#<channel> <text>` sends a text message.
    Node {
        #[arg(long)]
        community: PathBuf,
        #[arg(long)]
        data_dir: Option<PathBuf>,
        /// LiveKit server binary, run while this node hosts.
        #[arg(long, default_value = "livekit-server")]
        livekit_bin: PathBuf,
        /// Never host (e.g. a phone).
        #[arg(long)]
        no_host: bool,
        /// Print the LiveKit API key and secret when this node starts hosting (for `lk load-test`).
        #[arg(long)]
        print_lk_keys: bool,
    },
}

#[derive(Subcommand)]
enum CommunityCmd {
    /// Create a new community file.
    New {
        name: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Add a member to a community file.
    Add {
        file: PathBuf,
        member_hex: String,
        name: String,
        /// Member never hosts (e.g. a phone).
        #[arg(long)]
        no_host: bool,
    },
}

fn default_data_dir() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set; pass --data-dir")?;
    Ok(PathBuf::from(home).join(".hubbub-spike"))
}

struct NodeArgs {
    community: PathBuf,
    data_dir: PathBuf,
    livekit_bin: PathBuf,
    no_host: bool,
    print_lk_keys: bool,
}

async fn run_node(args: NodeArgs) -> Result<()> {
    let work_dir = args.data_dir.join("livekit");
    std::fs::create_dir_all(&work_dir).with_context(|| format!("creating {}", work_dir.display()))?;
    let ports = LkPorts::default();
    let livekit = LiveKitHost::new(args.livekit_bin, work_dir, ports);
    let (api_key, api_secret) = livekit.api_credentials();
    let lk_keys = serde_json::json!({
        "event": "LkKeys",
        "url": format!("ws://127.0.0.1:{}", ports.signal),
        "api_key": api_key,
        "api_secret": api_secret,
    })
    .to_string();
    let cfg = NodeConfig {
        data_dir: args.data_dir,
        community_file: args.community,
        can_host: !args.no_host,
        relay: RelayChoice::N0Default,
    };
    let node = Node::start(cfg, Box::new(livekit)).await?;
    let mut events = node.subscribe();
    let example = node.channels().text.first().map_or("#general hello".into(), |c| format!("#{c} hello"));
    eprintln!("hubbub node {} running; type `{example}` to send; Ctrl-C to leave", node.member_id().tag());
    let mut stdin = stdin_lines();
    let mut stdin_open = true;
    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);
    loop {
        tokio::select! {
            _ = &mut ctrl_c => break,
            line = stdin.recv(), if stdin_open => match line {
                Some(line) => send_line(&node, &line).await,
                // EOF, as when run with no terminal: keep running without input.
                None => stdin_open = false,
            },
            ev = events.recv() => match ev {
                Ok(ev) => {
                    println!("{}", serde_json::to_string(&ev)?);
                    if args.print_lk_keys && matches!(ev, NodeEvent::HostChanged { is_me: true, .. }) {
                        println!("{lk_keys}");
                    }
                }
                Err(RecvError::Lagged(n)) => eprintln!("hubbub node: {n} events dropped"),
                Err(RecvError::Closed) => break,
            },
        }
    }
    eprintln!("hubbub node: leaving");
    node.shutdown().await;
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
        eprintln!("hubbub node: to send a message, type #<channel> <text>");
        return;
    };
    match node.send_text(channel, body).await {
        Ok(_) if node.host_state().host.is_none() => {
            eprintln!("hubbub node: no host yet; the message goes out when one appears")
        }
        Ok(_) => {}
        Err(e) => eprintln!("hubbub node: message not sent: {e:#}"),
    }
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Id { data_dir } => {
            let dir = match data_dir {
                Some(d) => d,
                None => default_data_dir()?,
            };
            let id = Identity::load_or_create(&dir)?.member_id();
            println!("{} {}", id, id.tag());
        }
        Cmd::Node { community, data_dir, livekit_bin, no_host, print_lk_keys } => {
            let data_dir = match data_dir {
                Some(d) => d,
                None => default_data_dir()?,
            };
            let args = NodeArgs { community, data_dir, livekit_bin, no_host, print_lk_keys };
            tokio::runtime::Runtime::new()?.block_on(run_node(args))?;
        }
        Cmd::Community { cmd: CommunityCmd::New { name, out } } => {
            CommunityFile::create(&name).save(&out)?;
        }
        Cmd::Community { cmd: CommunityCmd::Add { file, member_hex, name, no_host } } => {
            let id: MemberId = member_hex.parse()?;
            let mut c = CommunityFile::load(&file)?;
            c.add_member(MemberEntry { id, name, can_host: !no_host });
            c.save(&file)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_text_line;

    #[test]
    fn text_lines_name_a_channel_then_the_message() {
        assert_eq!(parse_text_line("#general hello there"), Some(("general", "hello there")));
        assert_eq!(parse_text_line("#off-topic  two spaces"), Some(("off-topic", " two spaces")));
        assert_eq!(parse_text_line("#general"), None);
        assert_eq!(parse_text_line("general hello"), None);
    }
}
