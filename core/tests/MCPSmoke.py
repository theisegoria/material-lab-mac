#!/usr/bin/env python3
"""Drives `material-lab mcp` over stdio: handshake, tool list, derive -> preview -> export, and refusals."""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from CLISmoke import sample_png  # noqa: E402


class Client:
    def __init__(self, binary, *arguments):
        self.process = subprocess.Popen([binary, "mcp", *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.next_id = 0

    def write(self, text):
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()

    def read(self):
        line = self.process.stdout.readline()
        assert line, "server closed stdout: " + self.process.stderr.read()
        return json.loads(line)

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.write(json.dumps(message))
        reply = self.read()
        assert reply.get("id") == self.next_id, reply
        return reply

    def call(self, name, arguments=None):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert "result" in reply, reply
        return reply["result"]

    def ok(self, name, arguments=None):
        result = self.call(name, arguments)
        assert not result["isError"], result
        return result["content"]

    def refused(self, name, arguments, expected):
        result = self.call(name, arguments)
        assert result["isError"] and expected in result["content"][0]["text"], result

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=20) == 0


def main():
    binary = sys.argv[1]
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw).resolve()
        photo = root / "checker.png"
        sample_png(photo)
        client = Client(binary)

        hello = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                              "clientInfo": {"name": "smoke", "version": "0"}})["result"]
        assert hello["protocolVersion"] == "2025-06-18" and hello["serverInfo"]["name"] == "material-lab", hello
        assert "tools" in hello["capabilities"]
        client.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        assert client.request("ping")["result"] == {}

        tools = {tool["name"]: tool for tool in client.request("tools/list")["result"]["tools"]}
        assert set(tools) == {"list_presets", "list_formats", "derive_material", "export_material", "inspect_material",
                              "validate_material", "diff_materials", "preview_material"}, sorted(tools)
        for tool in tools.values():
            assert tool["description"] and tool["inputSchema"]["type"] == "object"

        # Malformed input and unknown methods get JSON-RPC errors and the server keeps going.
        client.write("{not json")
        assert client.read()["error"]["code"] == -32700
        assert client.request("no/such/method")["error"]["code"] == -32601
        assert client.request("tools/call", {"name": "no_such_tool"})["error"]["code"] == -32602

        presets = json.loads(client.ok("list_presets")[0]["text"])
        assert any(p["identifier"] == "red-brick" for p in presets)
        formats = json.loads(client.ok("list_formats")[0]["text"])
        assert {f["identifier"] for f in formats} >= {"glb", "usdz", "unreal"}

        bundle = root / "out" / "checker.pbrmaterial"
        summary = json.loads(client.ok("derive_material", {
            "input": str(photo), "output": str(root / "out" / "checker"), "preset": "red-brick", "roughness": 0.6,
            "bent_normal": True, "also_export": ["glb"], "label": "Checker"})[0]["text"])
        assert summary["bundle"] == str(bundle) and bundle.is_dir(), summary
        assert summary["exports"] == [str(root / "out" / "checker.glb")] and (root / "out" / "checker.glb").is_file()
        assert "material" in summary
        manifest = json.loads((bundle / "manifest.json").read_text())
        assert manifest["recipe"]["material_preset"] == "red-brick" and abs(manifest["recipe"]["roughness_base"] - 0.6) < 1e-6
        assert "bent_normal" in manifest["maps"]

        assert "valid" in client.ok("validate_material", {"path": str(bundle)})[0]["text"].lower()
        assert json.loads(client.ok("inspect_material", {"bundle": str(bundle)})[0]["text"])
        assert json.loads(client.ok("diff_materials", {"a": str(bundle), "b": str(bundle)})[0]["text"])

        preview = client.ok("preview_material", {"bundle": str(bundle)})
        assert preview[0]["type"] == "image" and preview[0]["mimeType"] == "image/jpeg"
        assert base64.b64decode(preview[0]["data"])[:2] == b"\xff\xd8"
        lit = client.ok("preview_material", {"bundle": str(bundle), "view": "lit"})
        assert base64.b64decode(lit[0]["data"])[:2] == b"\xff\xd8" and lit[0]["data"] != preview[0]["data"]
        client.refused("preview_material", {"bundle": str(bundle), "view": "x-ray"}, "maps or lit")
        assert not list(pathlib.Path(tempfile.gettempdir()).glob("material-lab-preview-*"))

        client.ok("export_material", {"bundle": str(bundle), "format": "unreal", "output": str(root / "ue")})
        assert (root / "ue").is_dir() and any((root / "ue").iterdir())

        # Nothing is overwritten, and bad arguments are tool errors (the server survives every one).
        client.refused("derive_material", {"input": str(photo), "output": str(bundle)}, "already exists")
        client.refused("export_material", {"bundle": str(bundle), "format": "unreal", "output": str(root / "ue")}, "already exists")
        client.refused("derive_material", {"input": str(photo), "output": str(root / "out" / "checker2"),
                                           "also_export": ["nope"]}, "unknown --also-export format")
        assert not (root / "out" / "checker2.pbrmaterial").exists()
        client.refused("derive_material", {"input": str(photo), "output": "relative/out"}, "absolute path")
        client.refused("derive_material", {"input": str(root / "missing.png"), "output": str(root / "m")}, "does not exist")
        client.refused("derive_material", {"input": str(photo), "output": str(root / "m"), "roughness": "high"}, "must be a number")
        client.refused("derive_material", {"input": str(photo), "output": str(root / "m"), "shell": "rm"}, "unknown argument")
        client.refused("derive_material", {"input": str(photo), "output": str(root / "m"), "roughness": 7}, "")
        client.refused("derive_material", {"input": str(photo), "output": "/usr/local/material-lab-smoke"}, "must be inside")
        client.refused("export_material", {"bundle": str(bundle), "format": "obj", "output": str(root / "o")}, "")
        client.refused("inspect_material", {"bundle": str(root)}, "")
        assert not (root / "m.pbrmaterial").exists()
        assert client.request("ping")["result"] == {}
        client.close()

        # --root confines reads and writes.
        inside = root / "inside"
        inside.mkdir()
        sample_png(inside / "a.png")
        client = Client(binary, "--root", str(inside))
        client.request("initialize", {"protocolVersion": "1999-01-01", "capabilities": {"roots": {}}})
        client.refused("derive_material", {"input": str(photo), "output": str(inside / "x")}, "--root")
        client.refused("derive_material", {"input": str(inside / "a.png"), "output": str(root / "x")}, "--root")
        client.refused("derive_material", {"input": str(inside / "a.png"), "output": str(inside / ".." / "x")}, "--root")
        client.refused("inspect_material", {"bundle": str(bundle)}, "--root")
        client.ok("derive_material", {"input": str(inside / "a.png"), "output": str(inside / "x")})
        assert (inside / "x.pbrmaterial" / "manifest.json").is_file()
        client.close()

        # A client that offers roots is asked for them, and they extend where the tools may write.
        client = Client(binary)
        client.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {"roots": {"listChanged": True}}})
        client.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        asked = client.read()
        assert asked["method"] == "roots/list", asked
        client.write(json.dumps({"jsonrpc": "2.0", "id": asked["id"], "result": {"roots": [{"uri": inside.as_uri()}]}}))
        assert client.request("ping")["result"] == {}
        client.close()

        bad = subprocess.run([binary, "mcp", "--root", str(root / "nowhere")], stdin=subprocess.DEVNULL, capture_output=True, text=True)
        assert bad.returncode == 1 and "--root" in bad.stderr
    print("MCP smoke test passed")


if __name__ == "__main__":
    main()
