use std::path::PathBuf;

use chrono::{Duration, Utc};
use dropdrawer_p2p::{P2pConfig, P2pNode};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        print_usage();
        return Ok(());
    }

    match args[1].as_str() {
        "seed" => {
            if args.len() < 3 {
                print_usage();
                return Ok(());
            }
            let file_path = PathBuf::from(&args[2]);
            let data_dir = args
                .get(3)
                .cloned()
                .unwrap_or_else(|| "./data/p2p-seed".to_string());
            let node = P2pNode::start(
                P2pConfig {
                    data_dir,
                    custom_relay_url: None,
                    disable_relay: false,
                },
                true,
            )
            .await?;

            let item_id = "cli-item".to_string();
            // A fresh secret per run: anyone who learns the node id must not
            // be able to pull the file with a well-known token.
            let token = uuid::Uuid::new_v4().simple().to_string();
            let info = node.register_file(item_id.clone(), &file_path).await?;
            node.authorize_token(item_id.clone(), token.clone(), Utc::now() + Duration::hours(1));

            // Allow a brief moment for relay/direct addr discovery
            tokio::time::sleep(std::time::Duration::from_millis(800)).await;
            let node_info = node.node_info();

            println!("=== DropDrawer P2P Seeding ===");
            println!("File   : {} ({} bytes)", info.path, info.size);
            println!("BLAKE3 : {}", info.blake3_hash);
            println!("Ticket : {}", serde_json::to_string(&node_info)?);
            println!("Token  : {token}");
            println!("Press Ctrl+C to stop seeding.");

            tokio::signal::ctrl_c().await?;
            node.shutdown().await;
        }
        "pull" => {
            if args.len() < 5 {
                print_usage();
                return Ok(());
            }
            let ticket_json = &args[2];
            let token = args[3].clone();
            let dest_path = PathBuf::from(&args[4]);
            let remote: dropdrawer_p2p::LocalNodeInfo = serde_json::from_str(ticket_json)?;

            let node = P2pNode::start(
                P2pConfig {
                    data_dir: "./data/p2p-pull".to_string(),
                    custom_relay_url: None,
                    disable_relay: false,
                },
                true,
            )
            .await?;

            let res = node
                .download_file(
                    "cli-item".to_string(),
                    remote.node_id,
                    remote.relay_url,
                    remote.direct_addrs,
                    token,
                    dest_path,
                )
                .await?;

            println!(
                "Downloaded {} bytes via {:?} -> {}",
                res.total_bytes,
                res.path_kind,
                res.saved_path.unwrap_or_default()
            );
            node.shutdown().await;
        }
        _ => print_usage(),
    }

    Ok(())
}

fn print_usage() {
    eprintln!("Usage:");
    eprintln!("  dropdrawer-p2p-cli seed <file_path> [data_dir]");
    eprintln!("  dropdrawer-p2p-cli pull '<ticket_json>' <token> <dest_path>");
}
