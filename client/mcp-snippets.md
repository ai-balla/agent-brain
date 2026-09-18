# MCP client snippets — connect your agents to the vault

Replace `<MCP_PUBLIC_URL>` with your endpoint (setup.sh prints it, e.g.
`https://hub.example.com/mcp`) and `<CF_ACCESS_CLIENT_ID>` /
`<CF_ACCESS_CLIENT_SECRET>` with the Cloudflare service token values.

---

## Claude Code

```json
{
  "mcpServers": {
    "agent-brain": {
      "type": "http",
      "url": "<MCP_PUBLIC_URL>",
      "headers": {
        "CF-Access-Client-Id": "<CF_ACCESS_CLIENT_ID>",
        "CF-Access-Client-Secret": "<CF_ACCESS_CLIENT_SECRET>"
      }
    }
  }
}
```

## Cursor / VS Code

In `~/.cursor/mcp.json` or the project `.mcp.json`:

```json
{
  "mcpServers": {
    "agent-brain": {
      "type": "http",
      "url": "<MCP_PUBLIC_URL>",
      "headers": {
        "CF-Access-Client-Id": "<CF_ACCESS_CLIENT_ID>",
        "CF-Access-Client-Secret": "<CF_ACCESS_CLIENT_SECRET>"
      }
    }
  }
}
```

## OpenCode

`opencode.json`:

```json
{
  "mcpServers": {
    "agent-brain": {
      "type": "remote",
      "url": "<MCP_PUBLIC_URL>",
      "headers": {
        "CF-Access-Client-Id": "<CF_ACCESS_CLIENT_ID>",
        "CF-Access-Client-Secret": "<CF_ACCESS_CLIENT_SECRET>"
      }
    }
  }
}
```

## Gemini CLI

`gemini mcp add` (or edit config):

```
gemini mcp add agent-brain <MCP_PUBLIC_URL> \
  --header CF-Access-Client-Id=<CF_ACCESS_CLIENT_ID> \
  --header CF-Access-Client-Secret=<CF_ACCESS_CLIENT_SECRET>
```

## Generic (Python SDK, official `mcp` package)

```python
import asyncio, os
import mcp.client.streamable_http as sh
from mcp import ClientSession

HOST = os.environ["MCP_PUBLIC_URL"]
HEADERS = {
    "CF-Access-Client-Id": os.environ["CF_ACCESS_CLIENT_ID"],
    "CF-Access-Client-Secret": os.environ["CF_ACCESS_CLIENT_SECRET"],
}

async def main():
    async with sh.httpx2.AsyncClient(headers=HEADERS) as http_client:
        async with sh.streamable_http_client(HOST, http_client=http_client) as streams:
            read, write = streams
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                print("tools:", [t.name for t in tools.tools])
                res = await session.call_tool("list_directory", {"path": "."})
                print(res.content[0].text)

asyncio.run(main())
```

## Tools exposed by the bridge

| Tool | Description |
|---|---|
| `vault_info` | root path + inventory counts |
| `list_directory` | one level (names + kinds) |
| `read_file` / `write_file` | UTF-8 notes inside the vault only |
| `create_directory` | mkdir -p inside the vault |
| `search_files` | glob by name or relative path |

All tools are path-restricted to the vault root (`/vault`); anything escaping
it returns a permission error.