# Warm Kiro ACP Client (kask)

A lightweight wrapper that keeps `kiro-cli` running as a persistent process via the Agent Client Protocol (ACP), eliminating startup overhead for repeated prompts. Uses `kimi-k2.5` for speed.

## Why

| Approach | Latency | Cost |
|----------|---------|------|
| `kiro-cli chat --no-interactive` (cold) | ~5-6s | Free (Pro license) |
| **kask warm prompt** | **faster** | **Free (Pro license)** |

## Setup

Installed automatically by `~/.cmux-kiro/setup.sh`:
- Client script: `~/bin/kiro-acp-client.py`
- Agent config: `~/.kiro/agents/fast.json` (symlinked from repo)
- Shell alias: `kask` (added to `~/.zshrc`)

## Usage

```bash
# One-shot (auto-starts daemon)
kask "summarize this error log"

# Pipe mode (auto-starts daemon)
echo "explain this" | kask

# Interactive REPL (direct, stays warm in-process)
kask
> what does this function do
> refactor it to use async
> quit

# Stop all daemons
kask --stop
```

## How it works

```
kask                          kiro-cli acp (Haiku 4.5)
  │── initialize ──────────────►│
  │◄── agentCapabilities ───────│
  │── session/new ─────────────►│
  │◄── {sessionId} ────────────│
  │                              │  ← session is now "warm"
  │── session/prompt ──────────►│
  │◄── session/update (chunks) ─│  ← streaming text
  │◄── {stopReason: end_turn} ──│
  │                              │
  │── session/prompt ──────────►│  ← next prompt, no re-init
  │◄── session/update (chunks) ─│
  │◄── {stopReason: end_turn} ──│
```

The process stays alive between prompts. The ACP protocol is JSON-RPC 2.0 over stdio (JSONL). Permission requests from the agent are auto-granted.

## Agent config

`~/.kiro/agents/fast.json`:
```json
{
  "name": "fast",
  "description": "Minimal agent for scripting - no MCP, no LSP, fast model",
  "model": "kimi-k2.5",
  "tools": ["@builtin"],
  "mcpServers": {}
}
```

Key choices:
- `kimi-k2.5` — fast model
- Empty `mcpServers` — skips MCP loading (biggest startup win)
- `@builtin` tools only — no external tool overhead

## References

- ACP protocol: https://agentclientprotocol.com/protocol/overview
- Reference implementation cribbed from: [SymphonyAgentOrchestrator/src/agent/kiro-runner.ts](https://code.amazon.com/packages/SymphonyAgentOrchestrator/blobs/mainline/--/src/agent/kiro-runner.ts)
- ACP types: [SymphonyAgentOrchestrator/src/agent/acp-types.ts](https://code.amazon.com/packages/SymphonyAgentOrchestrator/blobs/mainline/--/src/agent/acp-types.ts)
- Startup optimization tips from [Slack dump wiki](https://w.amazon.com/bin/view/Users/jusly/LLMDumpOctNov2025/) and [All Things AI](https://w.amazon.com/bin/view/AllThingsAI/2025_12_17/)

## Possible improvements

- **Daemon mode**: Unix socket server that keeps the ACP process warm across shell invocations
- **`--agent` flag**: Switch between fast (Haiku) and smart (Sonnet/Opus) per call
- **Timeout/retry**: Handle kiro-cli crashes and auto-restart the process
