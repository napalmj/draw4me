#!/bin/bash
# Builds the draw4me MCP server and puts it inside the Claude Code plugin (plugin/bin/).
# Then install the plugin from this folder:  /plugin marketplace add <this repo>  →  /plugin install draw4me@draw4me
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product draw4me-mcp
mkdir -p plugin/bin
cp "$(swift build -c release --show-bin-path)/draw4me-mcp" plugin/bin/draw4me-mcp
echo "Built plugin/bin/draw4me-mcp ($(plugin/bin/draw4me-mcp --version))"
