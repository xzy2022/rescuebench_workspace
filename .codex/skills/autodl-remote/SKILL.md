---
name: autodl-remote
description: Connect to and operate the user's AutoDL GPU server through the existing passwordless SSH alias autodl-t4. Use when Codex needs to log in to AutoDL, inspect the GPU or environment, execute remote commands and scripts, upload or download project files, launch and monitor research jobs, inspect logs, manage experiments, or troubleshoot an existing AutoDL connection.
---

# AutoDL Remote

Operate the configured AutoDL instance directly. Assume `ssh autodl-t4` and its dedicated private key already exist; do not regenerate keys or repeat public-key setup.

## Use the bundled command wrapper

Resolve `scripts/autodl-remote.ps1` relative to this `SKILL.md`. Use it for deterministic passwordless operations:

```powershell
# Verify the connection and current server state
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 -Action Probe

# Execute a remote command
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Run -Command "pwd; nvidia-smi"

# Upload a local file or directory
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Upload -LocalPath <local-path> -RemotePath /root/autodl-tmp/

# Download a remote file or directory
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Download -RemotePath <remote-path> -LocalPath <local-path> [-Recursive]
```

The wrapper enforces public-key-only authentication. Never pass or store an SSH password.

## Start every remote task safely

1. Run `Probe` once at the start of a remote task.
2. Read [references/server-profile.md](references/server-profile.md) when paths, environment, storage, ports, or long-running jobs matter.
3. Inspect relevant remote files and processes before changing them.
4. Keep work under `/root/autodl-tmp` unless the user explicitly chooses another location.
5. Preserve unrelated remote work and running processes.

If `Probe` fails, inspect `ssh -G autodl-t4` and `ssh -vvv autodl-t4 "exit"`. Report the failure. Do not regenerate or replace keys unless the user explicitly asks to repair authentication.

## Execute research commands

Prefer non-interactive remote commands over maintaining a persistent interactive terminal. Use:

```powershell
$remoteCommand = "cd /root/autodl-tmp/<project> && <command>"
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Run -Command $remoteCommand
```

Use explicit executables in automation:

```text
/root/miniconda3/bin/python
/root/miniconda3/bin/conda
```

Do not assume a non-interactive SSH shell loads Conda into `PATH`.

For commands that install packages, change environments, delete data, stop processes, or overwrite results, follow the user's exact scope and inspect targets first.

## Transfer files

Use `Upload` and `Download` rather than embedding passwords or connection details. The wrapper automatically uses recursive upload for a local directory. Pass `-Recursive` when downloading a remote directory.

Before overwriting a remote file, inspect its destination. For large datasets or checkpoints, prefer a resumable transfer method when available and verify size or checksums after transfer.

## Run long experiments

Do not leave training attached to the SSH process. Start it in a named `screen` session and redirect logs:

```powershell
$remoteCommand = "screen -dmS <session> bash -lc 'cd /root/autodl-tmp/<project> && /root/miniconda3/bin/python <script> > <log> 2>&1'"
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Run -Command $remoteCommand
```

Monitor without disturbing the job:

```text
screen -ls
tail -n 100 <log>
nvidia-smi
ps -eo pid,ppid,%cpu,%mem,etime,cmd --sort=-%cpu
```

Stop a session or process only when the user explicitly asks, and target its exact name or PID.

## Finish the task

Report:

- whether passwordless connection succeeded;
- the remote working directory used;
- commands or transfers completed;
- background session and log paths for long jobs;
- GPU/process status when relevant;
- any files or results the user should preserve before shutting down.

Never expose the private key, SSH password, access tokens, or unrelated remote secrets.
