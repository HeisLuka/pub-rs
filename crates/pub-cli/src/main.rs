use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(
    name = "pub",
    version,
    about = "Анализ файлов Microsoft Publisher .pub"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Показать структуру контейнера Compound File Binary.
    Inspect {
        path: PathBuf,
        #[arg(long)]
        json: bool,
    },
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Inspect { path, json } => {
            let inventory = pub_cfb::inspect_path(path)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&inventory)?);
            } else {
                for e in inventory.entries {
                    println!("{:?}\t{}\t{}", e.kind, e.len, e.path);
                }
            }
        }
    }
    Ok(())
}
