# DeerFlow VS Code Copilot Bridge

This VS Code extension exposes the official VS Code Language Model API on a loopback-only HTTP bridge so DeerFlow can use the GitHub Copilot models already available in the user's VS Code session.

The bridge does not read, export, or store Copilot tokens. VS Code handles Copilot authentication and asks the user for consent before an extension can send requests to Copilot language models.

## Endpoints

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`

The chat endpoint accepts an OpenAI Chat Completions shaped request and returns an OpenAI Chat Completions shaped response. It supports text responses and VS Code Language Model API tool-call parts.

## Development Run

`dist/extension.js` is checked in so the bridge can be launched in this Windows environment even before Node.js is installed. Install Node.js when you want to edit and recompile the TypeScript source.

## Ready-to-use Flow in This Environment

If you prefer a visual interface for DeerFlow itself, open `http://localhost:2026` in your browser. That UI handles login, setup, chat, and account settings. The helper scripts below are mainly for Copilot-to-DeerFlow automation.

From the current DeerFlow workspace terminal, run:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\start-vscode-copilot-bridge.ps1
```

That opens a new VS Code Extension Development Host window with the bridge loaded.

In that new window:

1. Open the command palette.
2. Run `DeerFlow Copilot Bridge: Start`.
3. If VS Code prompts for GitHub Copilot model access, approve it.
4. Watch the status bar entry `DeerFlow Bridge` instead of waiting for a toast notification.

After the command succeeds, the local bridge listens on `http://127.0.0.1:8765` and DeerFlow can use the `vscode-copilot` model already configured in [config.yaml](../../config.yaml).

Quick health check from the original terminal:

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8765/health" -Method Get
```

Expected shape:

```json
{
  "ok": true,
  "configured_model": "gpt-5.4",
  "configured_reasoning_effort": "xhigh",
  "request_ready": true,
  "request_probe": {
    "status": "ready",
    "model_id": "gpt-5.4",
    "error": null
  },
  "cached_model": {
    "id": "gpt-5.4"
  }
}
```

If `request_ready` is `false`, the bridge is up but VS Code has not finished granting or serving real Copilot requests yet. In that case, switch to the Extension Development Host window, approve any Copilot model access prompt, then run `DeerFlow Copilot Bridge: Start` again.

From this directory:

```powershell
npm install
npm run compile
code --extensionDevelopmentPath .
```

In the extension development window, run:

```text
DeerFlow Copilot Bridge: Start
```

Then configure DeerFlow with:

```yaml
models:
  - name: vscode-copilot
    display_name: VS Code Copilot Pro+
    use: deerflow.models.vscode_copilot_provider:VSCodeCopilotChatModel
    model: gpt-5.4
    base_url: http://127.0.0.1:8765
    request_timeout: 600.0
    max_retries: 2
    supports_reasoning_effort: true
    reasoning_effort: xhigh
```

You can copy that block and change `model:` to `gpt-5-mini` or `gpt-5.4-mini` if you want those Copilot variants exposed in DeerFlow as separate selectable models.

Those three ids are examples, not a fixed ceiling. The actual model ids you can use depend on your GitHub Copilot plan and whatever VS Code returns from `GET /v1/models` in the bridge inventory.

The bridge now defaults `copilot-auto` warmup requests to `gpt-5.4` and forwards `reasoning_effort: xhigh` unless the caller overrides it.

## One-click Self-check

After the bridge is started, run:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\check-deerflow-copilot-bridge.ps1
```

If DeerFlow auth is enabled, set credentials in the same terminal first:

```powershell
$env:DEERFLOW_EMAIL = "you@example.com"
$env:DEERFLOW_PASSWORD = "your-password"
```

On Windows, you can save the DeerFlow URL, email, password, and auto-initialize flag once through a small GUI:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\configure-vscode-to-deerflow.ps1
```

After that, both `chat.ps1` and `check-deerflow-copilot-bridge.ps1` will reuse the saved config automatically.

On first boot, either open `http://localhost:2026/setup`, or let the self-check create the first admin account for local development:

```powershell
$env:DEERFLOW_AUTO_INITIALIZE = "1"
pwsh -ExecutionPolicy Bypass -File .\scripts\check-deerflow-copilot-bridge.ps1
```

The script verifies:

- the bridge health endpoint
- that `gpt-5.4`, `gpt-5-mini`, and `gpt-5.4-mini` are visible in `/v1/models`
- that [config.yaml](../../config.yaml) is pinned to one of those Copilot models with `reasoning_effort: xhigh`
- an end-to-end DeerFlow request through the bridge when DeerFlow is already running
Use `model: copilot-auto` to select the first available Copilot model, or set `model` to a VS Code model id or family returned by `GET /v1/models`.

## Security Notes

- The server binds to `127.0.0.1` by default.
- Set `deerflowCopilotBridge.token` in VS Code settings to require `Authorization: Bearer <token>`.
- Do not bind this bridge to a public interface.

## Simple Usage Example

Once the bridge is started and DeerFlow itself is running, ask DeerFlow through the skill helper:

```powershell
pwsh -ExecutionPolicy Bypass -File .\skills\public\vscode-to-deerflow\scripts\chat.ps1 -Message "帮我总结这个仓库的前后端架构" -Mode pro
```

What happens:

- The script calls DeerFlow at `http://localhost:2026`.
- DeerFlow selects the `vscode-copilot` model from [config.yaml](../../config.yaml).
- The DeerFlow backend sends the request to the local bridge at `http://127.0.0.1:8765`.
- The bridge forwards the prompt to whichever Copilot model is configured there, such as `gpt-5.4`, `gpt-5-mini`, or `gpt-5.4-mini`, with `reasoning_effort: xhigh` by default.

If you want to continue the same DeerFlow conversation, reuse the returned `Thread ID`:

```powershell
pwsh -ExecutionPolicy Bypass -File .\skills\public\vscode-to-deerflow\scripts\chat.ps1 -Message "继续展开讲讲 agent 和 sandbox 的关系" -ThreadId "<thread-id>" -Mode pro
```
