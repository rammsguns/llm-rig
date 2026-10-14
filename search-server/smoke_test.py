"""Verify auth, MCP initialization/tool listing, and one actual web search."""
import asyncio
import json
from pathlib import Path
import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def main():
    url = "http://192.168.3.36:8091/mcp"
    key = (Path(__file__).parent / ".secrets/api-key").read_text().strip()
    async with httpx.AsyncClient(timeout=45) as anonymous:
        response = await anonymous.post(url, json={})
        assert response.status_code == 401, response.status_code
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}"}, timeout=45) as http:
        async with streamable_http_client(url, http_client=http) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert [tool.name for tool in tools.tools] == ["web_search"]
                result = await session.call_tool("web_search", {
                    "query": "Qwen official GitHub", "max_results": 3,
                })
                assert not result.isError, result.content
                data = result.structuredContent or json.loads(result.content[0].text)
                assert data and data["results"], result.content
                print(json.dumps({"auth": "401 without key", "mcp": "initialized",
                                  "search": data}, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
