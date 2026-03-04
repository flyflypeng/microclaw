npm --prefix web run build
RUST_LOG=debug MICROCLAW_CONFIG=~/.microclaw/microclaw.config.yaml cargo run -- start
