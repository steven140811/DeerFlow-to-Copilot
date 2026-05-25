# DeerFlow to Copilot

[English](./README.md) | [简体中文](./README_zh.md)

[![Windows Friendly](https://img.shields.io/badge/Windows-Friendly-0F6CBD?logo=windows&logoColor=white)](./scripts/start-deerflow-ui.ps1)
[![VS Code Copilot](https://img.shields.io/badge/VS%20Code-Copilot%20Bridge-007ACC?logo=visualstudiocode&logoColor=white)](./integrations/vscode-copilot-bridge/README.md)
[![Python](https://img.shields.io/badge/Python-3.12%2B-3776AB?logo=python&logoColor=white)](./backend/pyproject.toml)
[![Node.js](https://img.shields.io/badge/Node.js-22%2B-339933?logo=node.js&logoColor=white)](./frontend/package.json)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

![DeerFlow to Copilot workspace](./docs/assets/deerflow-to-copilot-hero.svg)

DeerFlow to Copilot is a Copilot-first secondary development based on DeerFlow 2.0. It keeps the original agent, memory, LangGraph, sandbox, and browser workspace foundation, but reorganizes the product around a simpler promise: if you already use GitHub Copilot in VS Code, you should be able to launch DeerFlow locally and start working in the browser without first wiring an extra model vendor just to try the product.

This repository is built for users who want a more direct path from editor to browser workspace.

- Reuse Copilot-backed models already available in VS Code through a local bridge.
- Start DeerFlow on Windows with a one-click launcher or a build task.
- Reduce first-run friction with optional admin initialization and local helper scripts.
- Switch between VS Code Copilot Pro+, GPT-5 mini, and GPT-5.4 mini in the UI.
- Keep browser chat, local scripts, and Copilot integration in one flow.

> Based on DeerFlow 2.0
>
> This project is an independent secondary development built on top of DeerFlow 2.0. The upstream project remains the original foundation and deserves full attribution. This fork narrows the first-run story for Copilot users and emphasizes direct usability, Windows ergonomics, and local bridge integration. See the upstream repository at [bytedance/deer-flow](https://github.com/bytedance/deer-flow).

## Why This Fork Exists

Original DeerFlow 2.0 is powerful, but first-time users still have to make several decisions before they see value: which model provider to use, how to bridge editor and browser workflows, how to run the stack comfortably on Windows, how to initialize the first admin, and how to keep local credentials manageable.

This fork changes that default path.

If you already have GitHub Copilot in VS Code, DeerFlow to Copilot lets DeerFlow call those Copilot models through a loopback-only bridge. That gets you to a working browser experience faster while keeping the upstream DeerFlow architecture underneath.

## What Changed From DeerFlow 2.0

| Area | Upstream DeerFlow 2.0 | DeerFlow to Copilot |
| --- | --- | --- |
| Default first-run story | Generic multi-provider onboarding | Copilot-first onboarding |
| VS Code integration | No built-in Copilot bridge | Local VS Code bridge for Copilot models |
| Windows startup | Git Bash oriented local flow | PowerShell one-click launcher with Docker or local fallback |
| First admin setup | Browser-driven manual setup | Launcher-assisted first admin initialization |
| Local credential reuse | Manual env var workflow | Local helper scripts for saved profile reuse |
| Model switching | Provider-specific manual setup | Ready-to-expose Copilot model variants in the UI |
| Product docs | Broad upstream surface | Focused step-by-step path for Copilot users |

## Product Strengths

### Copilot-first model access

The bridge described in [integrations/vscode-copilot-bridge/README.md](./integrations/vscode-copilot-bridge/README.md) lets DeerFlow call the Copilot models already available in your VS Code session. The bridge stays on loopback, depends on VS Code for Copilot authentication, and does not export Copilot tokens.

### Windows startup that feels productized

The launcher in [scripts/start-deerflow-ui.ps1](./scripts/start-deerflow-ui.ps1) prefers Docker when available, falls back to the local development path when necessary, can auto-start the Copilot bridge, can initialize the first admin account, and opens the browser UI when startup is done.

### Browser-first usage, not setup fatigue

The target experience is simple: open the browser, sign in, choose a model, choose a mode, and start asking for work. The launcher, bridge installer, and helper scripts are all aligned to that outcome.

### Multiple Copilot models ready for switching

![DeerFlow to Copilot model selector](./docs/assets/deerflow-to-copilot-model-switcher.svg)

The three entries below are examples, not a hardcoded limit. The actual model ids you can expose depend on your own GitHub Copilot plan and whatever the local bridge returns from `GET /v1/models` in your VS Code session.

Common examples in this fork are:

- VS Code Copilot Pro+ (`gpt-5.4`)
- VS Code Copilot GPT-5 mini (`gpt-5-mini`)
- VS Code Copilot GPT-5.4 mini (`gpt-5.4-mini`)

### Upstream DeerFlow remains under the hood

This is not a toy wrapper. You still keep the DeerFlow 2.0 base: LangGraph orchestration, memory, tools, sandbox support, skills, multi-step runs, and the browser workspace.

## Quick Start

The path below is optimized for public users who want to reach the browser UI quickly.

### 1. Prepare prerequisites

Install these first.

- VS Code with GitHub Copilot enabled
- Node.js 22+
- pnpm
- Python 3.12+
- uv
- nginx
- Docker Desktop if you want the easiest Windows path

### 2. Clone this repository

```bash
git clone https://github.com/steven140811/DeerFlow-to-Copilot.git
cd DeerFlow-to-Copilot
```

### 3. Create your local config file

```bash
make config
```

This creates a local `config.yaml` from the template. `config.yaml` is ignored by Git and should stay local.

### 4. Add the Copilot-backed models to `config.yaml`

Copy the Copilot examples from [config.example.yaml](./config.example.yaml) into your local `config.yaml`, or start with this block.

These three model entries are examples for a common Copilot setup, not a fixed requirement. If your own Copilot level exposes a different set of model ids in the bridge inventory, use those ids instead.

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
    supports_vision: false

  - name: vscode-copilot-gpt-5-mini
    display_name: VS Code Copilot GPT-5 mini
    use: deerflow.models.vscode_copilot_provider:VSCodeCopilotChatModel
    model: gpt-5-mini
    base_url: http://127.0.0.1:8765
    request_timeout: 600.0
    max_retries: 2
    supports_reasoning_effort: true
    reasoning_effort: xhigh
    supports_vision: false

  - name: vscode-copilot-gpt-5.4-mini
    display_name: VS Code Copilot GPT-5.4 mini
    use: deerflow.models.vscode_copilot_provider:VSCodeCopilotChatModel
    model: gpt-5.4-mini
    base_url: http://127.0.0.1:8765
    request_timeout: 600.0
    max_retries: 2
    supports_reasoning_effort: true
    reasoning_effort: xhigh
    supports_vision: false
```

### 5. Install the bridge into your main VS Code profile

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\install-vscode-copilot-bridge.ps1
```

After the script finishes, reload the current VS Code window once. That lets the main window load the bridge extension so you do not need a separate Extension Development Host for normal startup.

### 6. Optionally save local DeerFlow credentials once

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\configure-vscode-to-deerflow.ps1
```

That helper is for local convenience. Do not treat it as a shared or portable credential mechanism.

### 7. Start DeerFlow

You have two recommended launch paths on Windows.

Option A uses the build task after the bridge has been installed and the window reloaded.

- Press `Ctrl + Shift + B`.
- Choose `DeerFlow: One-click Launch UI`.

Option B runs the launcher directly.

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\start-deerflow-ui.ps1 -Email you@example.com
```

The `-Email` and `-Password` values are local credentials that you create yourself for this DeerFlow instance. They do not need a real sign-up, a real mailbox, or any external registration flow. They simply become the credentials you will use later when signing in to this local DeerFlow deployment.

If you do not pass `-Password`, the launcher can prompt for it securely. The launcher will:

- prefer Docker when Docker is available
- fall back to the local dev stack when Docker is not available
- start or verify the Copilot bridge by default
- initialize the first admin account when needed
- open the browser UI automatically

### 8. Use DeerFlow in the browser

When startup completes, open or keep using `http://localhost:2026`.

Then follow this order.

1. Finish setup or sign in with the same local email and password you created during first boot.
2. Open the main workspace.
3. Select one of the Copilot-backed models from the model switcher.
4. Choose a mode that matches the task.
5. Start chatting in the browser.

The main modes are:

- `flash` for the fastest path
- `standard` for balanced interactive work
- `pro` for deeper planning and higher effort tasks
- `ultra` for planning plus subagents on heavier work

### 9. Run the bridge self-check when you want verification

Fast validation:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\check-deerflow-copilot-bridge.ps1 -SkipRoundTrip
```

Full end-to-end validation:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\check-deerflow-copilot-bridge.ps1
```

## Step-by-Step: From Clone To Browser Use

If you want the shortest possible mental model, it is this.

1. Clone the repo.
2. Generate `config.yaml`.
3. Add the Copilot model entries.
4. Install the bridge into the main VS Code profile.
5. Reload VS Code once.
6. Run the one-click launcher or the VS Code build task.
7. Open `http://localhost:2026`.
8. Sign in or finish setup.
9. Pick a model and mode in the browser.
10. Use DeerFlow from the browser while Copilot-backed models run through the local VS Code bridge.

## Detailed Difference Map

For a deeper, file-oriented analysis of how this project diverges from DeerFlow 2.0, see [docs/DEERFLOW_TO_COPILOT_DIFF.md](./docs/DEERFLOW_TO_COPILOT_DIFF.md).

That document covers:

- the Copilot bridge and backend provider layer
- one-click launch, bridge install, and Windows automation scripts
- frontend mode and model handling changes
- service routing and local proxy behavior
- configuration and skill packaging changes

## Security And Compliance

This repository is being positioned for public use, so the release rules are simple.

- Do not commit `config.yaml`, `.env`, local credential files, or API keys.
- Keep the bridge bound to `127.0.0.1` unless you fully understand the security implications.
- GitHub Copilot authentication remains inside VS Code.
- Local helper data is for the local machine and user context only.
- Preserve upstream attribution and the MIT license terms from DeerFlow 2.0.

This project is an independent community-facing secondary development. It is not presented as an official GitHub, Microsoft, or ByteDance product.

## Public Release Checklist

Before pushing this repository to a public GitHub repo, verify all of the following.

- `config.yaml` is still ignored and not staged
- `.env` is not staged
- no passwords, access tokens, or API keys were written into tracked files
- images do not contain secrets
- README instructions reference template files, not private local files

## Where To Read More

- [Install.md](./Install.md)
- [config.example.yaml](./config.example.yaml)
- [integrations/vscode-copilot-bridge/README.md](./integrations/vscode-copilot-bridge/README.md)
- [skills/public/vscode-to-deerflow/SKILL.md](./skills/public/vscode-to-deerflow/SKILL.md)
- [SECURITY.md](./SECURITY.md)
- [Original DeerFlow 2.0](https://github.com/bytedance/deer-flow)

## Upstream Credit

The original DeerFlow 2.0 project remains the foundation of this work. If you want the broader upstream documentation, provider matrix, or roadmap, read the upstream repository directly. This fork exists to serve a narrower product goal: help Copilot users get to a working DeerFlow browser experience faster and with less integration overhead.
