# Web-search MCP server for OpenCode

One tool, `web_search`, with up to 10 short results. Uses DDGS public search
backends without a paid API key. Queries go to external providers; results can
be incomplete or fail due to provider rate limits. Search content is untrusted.
No local-file access, arbitrary URL fetching, GPU use, or model changes.

## Start / stop

```bash
cd /home/kiwi/llm-rig/search-server
bash start.sh
```

Keep the terminal open; Ctrl+C stops the server. This is not a boot service.
Dependencies are installed in `.venv`. To recreate:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Server endpoint: `http://192.168.3.36:8091/mcp`. Every HTTP request requires
`Authorization: Bearer <key>`. The generated key lives in `.secrets/api-key`
(mode 600). This is separate from the Strata API key. Display it on this rig:

```bash
cd /home/kiwi/llm-rig/search-server
head -n 1 .secrets/api-key
```

## Connect OpenCode on the other machine

Merge `opencode.example.json` into your existing OpenCode configuration; do not
replace your model/provider settings. Set `SEARCH_API_KEY` in the shell that
launches OpenCode to the key displayed above, then restart OpenCode. For example:

```bash
export SEARCH_API_KEY='paste-search-key-here'
opencode mcp list
opencode
```

Prompt: "Use web_search to find the latest official Qwen announcements."
This example uses the OpenCode v1 `mcp` map. OpenCode v2 uses `mcp.servers`
and `disabled: false` instead of `enabled: true`; check `opencode --version`.

Use only on a trusted LAN. No router/firewall rules are changed. Plain HTTP does
not encrypt the key or queries; use an SSH tunnel/VPN on untrusted networks.
Allowed Host/Origin values are localhost and this rig's current LAN IP; update
`server.py` if its IP changes. `SEARCH_HOST=127.0.0.1 bash start.sh` restricts
listening to localhost; `SEARCH_PORT` changes the port.

References: [OpenCode MCP configuration](https://opencode.ai/docs/mcp-servers/),
[MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk),
[DDGS](https://github.com/deedy5/ddgs).
