# DeerFlow to Copilot Difference Map

This document explains how this repository diverges from DeerFlow 2.0 at the product level. It is not a line-by-line changelog. It is a release-oriented map of what changed, why it changed, and which files carry the change.

## Positioning Shift

The biggest change is not a single file. It is the product story.

DeerFlow 2.0 is a general-purpose super-agent harness. DeerFlow to Copilot is a Copilot-first secondary development built to help GitHub Copilot users reach a working local DeerFlow browser workflow faster.

That positioning shift changes the default answers to several questions.

| Question | Upstream default | This repository |
| --- | --- | --- |
| Who is the first target user | Broad DeerFlow adopter | VS Code plus Copilot user |
| What is the first model path | Generic provider configuration | Copilot models already available in VS Code |
| What is the first launch goal | Service stack readiness | Browser usability at `http://localhost:2026` |
| What is the Windows story | Supported but still closer to dev tooling | One-click startup and bridge installation |
| What is the preferred workflow | General config-first onboarding | Copilot bridge plus browser-first onboarding |

## Difference 1: Copilot Bridge Layer

Change: this repository adds a local VS Code extension bridge so DeerFlow can use the GitHub Copilot models already available in the user's VS Code session.

Key files:

- [integrations/vscode-copilot-bridge/src/extension.ts](../integrations/vscode-copilot-bridge/src/extension.ts)
- [integrations/vscode-copilot-bridge/package.json](../integrations/vscode-copilot-bridge/package.json)
- [integrations/vscode-copilot-bridge/README.md](../integrations/vscode-copilot-bridge/README.md)
- [scripts/start-vscode-copilot-bridge.ps1](../scripts/start-vscode-copilot-bridge.ps1)
- [scripts/install-vscode-copilot-bridge.ps1](../scripts/install-vscode-copilot-bridge.ps1)
- [scripts/check-deerflow-copilot-bridge.ps1](../scripts/check-deerflow-copilot-bridge.ps1)

Why it matters: this is the biggest functional departure from upstream DeerFlow 2.0. Instead of forcing the user to bring a separate vendor API just to get started, the bridge lets DeerFlow call Copilot-backed models through a loopback-only HTTP surface.

README implication: the public README should explicitly say that this project is designed to reduce extra provider setup for existing Copilot users, not to remove all other provider possibilities forever.

## Difference 2: Backend Provider For Copilot Models

Change: a dedicated backend chat model provider was added so the DeerFlow backend can speak to the local bridge using OpenAI-shaped requests and responses.

Key files:

- [backend/packages/harness/deerflow/models/vscode_copilot_provider.py](../backend/packages/harness/deerflow/models/vscode_copilot_provider.py)
- [backend/packages/harness/deerflow/models/factory.py](../backend/packages/harness/deerflow/models/factory.py)
- [backend/tests/test_vscode_copilot_provider.py](../backend/tests/test_vscode_copilot_provider.py)
- [backend/tests/test_model_factory.py](../backend/tests/test_model_factory.py)

Why it matters: without this layer, the bridge would only be a sidecar utility. With it, Copilot-backed models become first-class DeerFlow models that can participate in model selection, reasoning effort, tool calls, and runtime factory logic.

README implication: the README should emphasize that Copilot-backed models are selectable in the DeerFlow UI and that reasoning effort is supported for the configured Copilot models.

## Difference 3: One-click Startup And First-run Automation

Change: the Windows startup path was redesigned around a PowerShell launcher that handles mode selection, startup orchestration, optional admin initialization, bridge startup, and browser opening.

Key files:

- [scripts/start-deerflow-ui.ps1](../scripts/start-deerflow-ui.ps1)
- [scripts/configure-vscode-to-deerflow.ps1](../scripts/configure-vscode-to-deerflow.ps1)
- [skills/public/vscode-to-deerflow/scripts/profile.ps1](../skills/public/vscode-to-deerflow/scripts/profile.ps1)
- [skills/public/vscode-to-deerflow/scripts/configure.ps1](../skills/public/vscode-to-deerflow/scripts/configure.ps1)
- [skills/public/vscode-to-deerflow/scripts/chat.ps1](../skills/public/vscode-to-deerflow/scripts/chat.ps1)

Why it matters: upstream DeerFlow is developer-friendly, but this fork is trying to behave more like an installable local product. One-click launch, saved local profile data, and first-run admin handling reduce the amount of manual setup that blocks the first real browser session.

README implication: the README should teach users how to reach the browser UI, not just how to start a process.

## Difference 4: Service Routing And Local Runtime Behavior

Change: the local serving path and nginx proxy behavior were adjusted to make the unified local endpoint more reliable for the new browser-first flow.

Key files:

- [scripts/serve.sh](../scripts/serve.sh)
- [scripts/wait-for-port.sh](../scripts/wait-for-port.sh)
- [docker/nginx/nginx.local.conf](../docker/nginx/nginx.local.conf)

Why it matters: this repository depends on a stable same-origin entry point at `http://localhost:2026`. That address is the center of the browser workflow, the first-run experience, and the saved local profile.

README implication: the README should use the unified browser address consistently and avoid sending users through multiple port explanations unless necessary.

## Difference 5: Frontend Interaction And Mode Handling

Change: the frontend logic was adjusted so mode selection and thinking or reasoning behavior align with the Copilot-backed model capabilities.

Key files:

- [frontend/src/components/workspace/input-box.tsx](../frontend/src/components/workspace/input-box.tsx)
- [frontend/src/core/threads/hooks.ts](../frontend/src/core/threads/hooks.ts)
- [frontend/src/core/threads/types.ts](../frontend/src/core/threads/types.ts)
- [frontend/tsconfig.json](../frontend/tsconfig.json)

Why it matters: for end users, this is the difference between a dropdown that looks correct and a workflow that actually behaves correctly. The changes here make sure model support, plan mode, thinking mode, and reasoning effort are not treated as the same thing.

README implication: the README should explicitly say that users can switch models in the browser and choose modes such as flash, standard, pro, and ultra.

## Difference 6: Config Template And Documentation Direction

Change: the config template now contains Copilot-oriented examples, and the documentation direction shifts from broad upstream coverage toward a narrower Copilot-first onboarding path.

Key files:

- [config.example.yaml](../config.example.yaml)
- [README.md](../README.md)
- [README_zh.md](../README_zh.md)
- [Install.md](../Install.md)
- [skills/public/vscode-to-deerflow/SKILL.md](../skills/public/vscode-to-deerflow/SKILL.md)

Why it matters: product adoption depends on documentation matching the actual product story. If the docs still read like upstream DeerFlow while the code behaves like a Copilot-first product, new users will make the wrong assumptions and hit the wrong setup path.

README implication: the README should lead with value, then with the shortest stable setup path, then with precise security boundaries.

## Difference 7: Local Skill Packaging For Editor-to-Browser Flow

Change: the repository adds a dedicated `vscode-to-deerflow` skill package so Copilot and local scripts can interact with the DeerFlow API surface more directly.

Key files:

- [skills/public/vscode-to-deerflow/SKILL.md](../skills/public/vscode-to-deerflow/SKILL.md)
- [skills/public/vscode-to-deerflow/scripts/chat.ps1](../skills/public/vscode-to-deerflow/scripts/chat.ps1)
- [skills/public/vscode-to-deerflow/scripts/profile.ps1](../skills/public/vscode-to-deerflow/scripts/profile.ps1)

Why it matters: this turns the integration from a one-off bridge into a usable workflow layer. It is part of why this repo feels like a product fork, not just a patch set.

## What The Public README Should Emphasize

- This project is based on DeerFlow 2.0.
- This is a secondary development focused on Copilot users.
- The main benefit is lower setup overhead for users who already have GitHub Copilot in VS Code.
- The recommended success path ends in the browser at `http://localhost:2026`.
- The Windows path is intentionally optimized.
- The Copilot bridge stays local and does not export Copilot tokens.
- The upstream project still deserves attribution and a direct link.

## What The Public README Should Not Claim

- Do not claim this is an official GitHub, Microsoft, or ByteDance product.
- Do not claim users never need any external model provider under any circumstances.
- Do not imply that Copilot authentication is handled by this repository.
- Do not present local convenience scripts as enterprise credential management.

## Public Release Safety Rules

Before pushing publicly, confirm all of the following:

- `config.yaml` is still ignored.
- `.env` is still ignored.
- No access tokens, passwords, or API keys appear in tracked files.
- Published screenshots or assets contain no secrets.
- The repo still preserves upstream licensing and attribution.

## Bottom Line

The essential change is straightforward.

DeerFlow 2.0 is the foundation. DeerFlow to Copilot is the productized local experience built on top of it for Copilot users who want to get from VS Code to a working DeerFlow browser workflow with less setup friction.
