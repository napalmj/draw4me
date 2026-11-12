import Foundation
import Draw4MeMCP

// draw4me MCP server (stdio). Claude Code / the Claude desktop app launch this; it forwards tool
// calls to the running draw4me app over a private local socket, or works headlessly on a file.
// Logs go to stderr; stdout carries only JSON-RPC messages.
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--version") {
    print("draw4me-mcp \(MCPServer.serverVersion)")
    exit(0)
}
MCPServer().runStdio()
