# DeerFlow to Copilot Install

This file is for coding agents and automation helpers.

If the repository is not already cloned and open, clone `https://github.com/steven140811/DeerFlow-to-Copilot.git` first, then continue from the repository root.

## Goal

Bootstrap a DeerFlow to Copilot workspace with the least risky path available, then stop with the exact next action the user needs.

Default preference order:

1. Windows one-click path with VS Code Copilot bridge
2. Docker development path
3. Local development path

## Operating Rules

- Be idempotent.
- Prefer existing repository scripts over ad hoc shell commands.
- Do not install system packages without explicit user approval.
- Do not overwrite existing user config values unless asked.
- Do not inspect `.env`, `frontend/.env`, or any other secret-bearing file.
- Do not commit or push changes unless the user explicitly asks.
- If a step fails, stop and report the smallest next action.

## Success Criteria

Consider setup successful when all of the following are true:

- The current working directory is the repository root.
- `config.yaml` exists.
- The Copilot bridge extension is installed into the main VS Code profile when the user wants the Copilot-first path.
- The user receives the exact launch command or build-task path for their machine.
- The user also receives any missing config or credential placeholders that still need real values.

## Required Checks

Before changing anything:

- Confirm the current directory contains `Makefile`, `backend/`, `frontend/`, `scripts/`, and `config.example.yaml`.
- Detect whether `config.yaml` already exists.
- Detect whether Docker is available with `docker info`.
- Detect whether the OS is Windows.

## Preferred Windows Copilot-first Path

Use this path when all of the following are true:

- The OS is Windows.
- VS Code is part of the user's workflow.
- The user wants the simplest path to a working browser UI backed by Copilot models.

Steps:

1. If `config.yaml` does not exist, run `make config`.
2. Tell the user to copy the Copilot model examples from `config.example.yaml` into `config.yaml` if they are not already present.
3. Run:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\scripts\install-vscode-copilot-bridge.ps1
   ```

4. Tell the user that the current VS Code window should be reloaded once after bridge installation.
5. If the user wants local credential reuse, run:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\scripts\configure-vscode-to-deerflow.ps1
   ```

6. Stop at the setup boundary and tell the user to launch DeerFlow with either:

   - `Ctrl + Shift + B` then `DeerFlow: One-click Launch UI`
   - or:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\scripts\start-deerflow-ui.ps1 -Email you@example.com
   ```

## Docker Development Path

Use this path when Docker is available and the user does not specifically require the Windows one-click flow.

Steps:

1. If `config.yaml` does not exist, run `make config`.
2. Run:

   ```bash
   make docker-init
   ```

3. Stop at the setup boundary and tell the user that the next command is:

   ```bash
   make docker-start
   ```

4. Tell the user that the browser entry is `http://localhost:2026` after services are up.

## Local Development Path

Use this path when Docker is unavailable or the user explicitly wants the local development stack.

Steps:

1. If `config.yaml` does not exist, run `make config`.
2. Run:

   ```bash
   make check
   ```

3. If `make check` reports missing tools, stop and report them.
4. If prerequisites are satisfied, run:

   ```bash
   make install
   ```

5. Stop at the setup boundary and tell the user that the next command is:

   ```bash
   make dev
   ```

6. Tell the user that the browser entry is `http://localhost:2026` after services are up.

## What To Inspect In `config.yaml`

Inspect `config.yaml` only for non-secret structure.

- Verify that at least one model entry exists.
- If the user wants the Copilot-first path, verify that `vscode-copilot` style entries exist.
- If the file references environment variables such as `$OPENAI_API_KEY`, report the variable names without inspecting secret files.

## Verification

Use the lightest matching verification.

Windows Copilot-first path:

- Confirm `config.yaml` exists.
- Confirm the bridge installer completed successfully.
- Report that the next step is a VS Code reload plus the launcher.

Docker path:

- Confirm `config.yaml` exists.
- Confirm `make docker-init` completed successfully.
- Report that `make docker-start` is still the first real launch step.

Local path:

- Confirm `config.yaml` exists.
- Confirm `make install` completed successfully.
- Report that `make dev` is still the first real launch step.

## Final Response Format

Return a short status report with:

1. Setup path used
2. Setup level reached
3. Files created or detected
4. Remaining user action
5. Exact next launch command

## Execute Now

Complete the applicable setup path above. Stop at the setup boundary instead of drifting into unrelated work.
