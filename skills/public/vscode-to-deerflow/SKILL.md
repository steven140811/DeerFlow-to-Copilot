---
name: vscode-to-deerflow
description: "Use GitHub Copilot in VS Code to communicate with a running DeerFlow instance over its HTTP API. Use this skill when the user asks Copilot to delegate research, analysis, planning, file upload, memory inspection, model listing, skill listing, thread management, or deep research tasks to DeerFlow. Also use when the user mentions deerflow, deer flow, vscode-to-deerflow, or wants Copilot to ask DeerFlow for a second agentic pass."
---

# VS Code to DeerFlow

Communicate with a running DeerFlow instance from GitHub Copilot in VS Code. DeerFlow is a LangGraph-based agent platform that can plan, research, call tools, use skills, run subagents, and maintain conversation threads.

For a visual interface, use DeerFlow's web UI at `http://localhost:2026`. It includes login, setup, chat, and workspace settings pages.

## Operating Rules for Copilot

- Use PowerShell examples on Windows and the integrated terminal when running helper commands.
- Resolve URLs from environment variables before making API requests.
- Do not inspect `.env`, `frontend/.env`, API keys, tokens, or other secret-bearing files.
- If DeerFlow is not reachable, tell the user to start DeerFlow and include the exact start command for their setup.
- Reuse a `thread_id` when the user is continuing the same DeerFlow conversation.

## Architecture

DeerFlow exposes two API surfaces behind the local proxy:

| Service | Direct Port | Via Proxy | Purpose |
| --- | --- | --- | --- |
| Gateway API | 8001 | `$DEERFLOW_GATEWAY_URL` | REST endpoints for health, models, skills, memory, uploads |
| LangGraph-compatible API | 8001 | `$DEERFLOW_LANGGRAPH_URL` | Threads, runs, streaming, history |

## Environment Variables

Read these variables before making a request:

| Variable | Default | Description |
| --- | --- | --- |
| `DEERFLOW_URL` | `http://localhost:2026` | Unified proxy base URL |
| `DEERFLOW_GATEWAY_URL` | value of `DEERFLOW_URL` | Gateway API base |
| `DEERFLOW_LANGGRAPH_URL` | `${DEERFLOW_URL}/api/langgraph` via proxy, `http://localhost:8001/api` when direct | LangGraph-compatible API base |
| `DEERFLOW_EMAIL` | unset | DeerFlow login email for authenticated LangGraph requests |
| `DEERFLOW_PASSWORD` | unset | DeerFlow login password for authenticated LangGraph requests |
| `DEERFLOW_AUTO_INITIALIZE` | unset | Set to `1` only on first boot to create the first admin through the script |

In PowerShell, resolve them like this:

```powershell
$DeerFlowUrl = if ($env:DEERFLOW_URL) { $env:DEERFLOW_URL } else { "http://localhost:2026" }
$GatewayUrl = if ($env:DEERFLOW_GATEWAY_URL) { $env:DEERFLOW_GATEWAY_URL } else { $DeerFlowUrl }
$LangGraphUrl = if ($env:DEERFLOW_LANGGRAPH_URL) { $env:DEERFLOW_LANGGRAPH_URL } else { "$DeerFlowUrl/api/langgraph" }
```

## Primary Operation: Send a Message

Prefer the helper script from this skill directory:

```powershell
pwsh -ExecutionPolicy Bypass -File .\skills\public\vscode-to-deerflow\scripts\chat.ps1 -Message "Your question here"
```

If DeerFlow auth is enabled, set credentials in the current terminal first:

```powershell
$env:DEERFLOW_EMAIL = "you@example.com"
$env:DEERFLOW_PASSWORD = "your-password"
```

On Windows, you can save these values once with a small GUI instead of typing env vars every time:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\configure-vscode-to-deerflow.ps1
```

After saving, `chat.ps1` and `check-deerflow-copilot-bridge.ps1` will load the saved config automatically.

On the very first boot, either finish setup in the browser at `http://localhost:2026/setup`, or allow the script to initialize the first admin account:

```powershell
$env:DEERFLOW_AUTO_INITIALIZE = "1"
```

Continue an existing thread:

```powershell
pwsh -ExecutionPolicy Bypass -File .\skills\public\vscode-to-deerflow\scripts\chat.ps1 -Message "Follow up" -ThreadId "<thread_id>"
```

Choose a mode:

```powershell
pwsh -ExecutionPolicy Bypass -File .\skills\public\vscode-to-deerflow\scripts\chat.ps1 -Message "Research this" -Mode ultra
```

Modes:

| Mode | Context |
| --- | --- |
| `flash` | no thinking, no planning, no subagents |
| `standard` | thinking enabled, no planning, no subagents |
| `pro` | thinking and planning enabled |
| `ultra` | thinking, planning, and subagents enabled |

## Direct HTTP Operations

Health check:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/health" -Method Get
```

List models:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/api/models" -Method Get
```

List skills:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/api/skills" -Method Get
```

List agents:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/api/agents" -Method Get
```

Get memory:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/api/memory" -Method Get
```

Create a thread:

```powershell
$Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-RestMethod -Uri "$GatewayUrl/api/v1/auth/login/local" -Method Post -Body @{ username = $env:DEERFLOW_EMAIL; password = $env:DEERFLOW_PASSWORD } -WebSession $Session | Out-Null
$CsrfToken = $Session.Cookies.GetCookies([System.Uri]$GatewayUrl)["csrf_token"].Value
$Thread = Invoke-RestMethod -Uri "$LangGraphUrl/threads" -Method Post -ContentType "application/json" -Body "{}" -WebSession $Session -Headers @{ "X-CSRF-Token" = $CsrfToken }
$Thread.thread_id
```

Upload files to a thread:

```powershell
$Form = @{ files = Get-Item "C:\path\to\file.pdf" }
Invoke-RestMethod -Uri "$GatewayUrl/api/threads/<thread_id>/uploads" -Method Post -Form $Form
```

List uploaded files:

```powershell
Invoke-RestMethod -Uri "$GatewayUrl/api/threads/<thread_id>/uploads/list" -Method Get
```

List recent threads:

```powershell
$Body = @{ limit = 20; sort_by = "updated_at"; sort_order = "desc" } | ConvertTo-Json
Invoke-RestMethod -Uri "$LangGraphUrl/threads/search" -Method Post -ContentType "application/json" -Body $Body
```

## Error Handling

- Health check fails: DeerFlow is not running or the URL is wrong.
- `CSRF token missing` or `Authentication required`: log in first with `DEERFLOW_EMAIL` and `DEERFLOW_PASSWORD`, or finish first-run setup.
- Empty model list: `config.yaml` has no active model entries.
- Stream error event: surface the DeerFlow error message directly.
- PowerShell `curl` ambiguity: prefer `Invoke-RestMethod`, `Invoke-WebRequest`, or `curl.exe` explicitly.

## Tips

- Use `flash` for quick checks and `pro` or `ultra` for research tasks.
- Capture and show the `Thread ID` after each run so follow-ups can reuse it.
- For file-heavy tasks, upload files first and then mention them in the DeerFlow prompt.
- If you want a visual conversation experience instead of script-driven prompts, open `http://localhost:2026`, sign in, and use the built-in workspace UI.