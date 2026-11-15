#pragma once
// `material-lab mcp`: a Model Context Protocol server on stdin/stdout (newline-delimited JSON-RPC 2.0), so an
// agent can derive, inspect, preview and export materials. Each tool runs the CLI's own code in-process.
#include <functional>
#include <string>
#include <vector>

namespace mlmcp {
// Runs the CLI with `arguments` (no argv[0]); fills what it printed. Returns the exit code; never throws.
using Invoke = std::function<int(const std::vector<std::string>& arguments, std::string& out, std::string& err)>;

// Serves until stdin closes. `roots` (from --root) confine every path the tools read or write; when empty, reads
// are unrestricted and writes are confined to the client's roots (if it offers any), the home directory and the
// temporary directories. Nothing is ever overwritten.
int serve(const std::vector<std::string>& roots, const Invoke& invoke, const char* version);
}
