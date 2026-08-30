---
name: autodl-remote
description: Connect to and operate the user's AutoDL GPU server through the project-managed passwordless SSH configuration and alias autodl-t4. Use when Codex needs to log in to AutoDL, inspect the GPU or environment, execute remote commands and scripts, upload or download project files, launch and monitor research jobs, inspect logs, manage experiments, or troubleshoot an existing AutoDL connection.
---

# AutoDL Remote

Operate the configured AutoDL instance directly. The project-root `autodl-ssh.config` is the source of truth for the `autodl-t4` endpoint and dedicated private-key path. Do not regenerate keys or repeat public-key setup.

## Maintain the current endpoint

Before connecting to a newly created instance, update only `HostName` and `Port` in the project-root `autodl-ssh.config` from the current AutoDL console SSH command. Never store a password or private-key contents in that file. 

The wrapper uses the project config by default. Pass `-SshConfigPath <path>` only when the user explicitly chooses a different OpenSSH config file.

## Use the bundled command wrapper

Resolve `scripts/autodl-remote.ps1` relative to this `SKILL.md`. Use it for deterministic passwordless operations:

```powershell
# Verify the connection and current server state
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 -Action Probe

# Execute a remote command
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Run -Command "pwd; nvidia-smi"

# Start a detached long-running job with a unique remote log
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action StartJob `
  -ProjectName <project> `
  -SessionName <session> `
  -WorkingDirectory /root/autodl-tmp/<project> `
  -Command "/root/miniconda3/bin/python -u <script>"

# Inspect whether a job is still running and tail its exact log
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action JobStatus `
  -SessionName <session> `
  -LogPath <path-returned-by-StartJob> `
  -TailLines 100

# Upload a local file or directory
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Upload -LocalPath <local-path> -RemotePath /root/autodl-tmp/

# Download a remote file or directory
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action Download -RemotePath <remote-path> -LocalPath <local-path> [-Recursive]
```

`Probe` reports the current identity, OS, GPU and CUDA state, base Python/PyTorch and Conda state, remote job tools, storage mounts, and top-level data-disk directories. Treat reported `missing` values as findings to inspect; the probe never installs or repairs them.

The wrapper enforces public-key-only authentication. Never pass or store an SSH password.

## Start every remote task safely

1. Run `Probe` once at the start of a remote task.
2. Read [references/server-profile.md](references/server-profile.md) when paths, environment, storage, ports, or long-running jobs matter.
3. Inspect relevant remote files and processes before changing them.
4. Keep work under `/root/autodl-tmp` unless the user explicitly chooses another location.
5. Preserve unrelated remote work and running processes.

If `Probe` fails, inspect `ssh -F <project-root>\autodl-ssh.config -G autodl-t4` and `ssh -F <project-root>\autodl-ssh.config -vvv autodl-t4 "exit"`. Report the failure. Do not regenerate or replace keys unless the user explicitly asks to repair authentication.

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

Do not leave training attached to the SSH process or construct an ad hoc
`screen` command. Use `StartJob`; it validates the paths and session name,
refuses duplicate sessions and existing log files, starts a detached `screen`
session, merges stdout/stderr into a unique remote log, and records timestamps
and the final job exit code:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action StartJob `
  -ProjectName <project> `
  -SessionName <session> `
  -WorkingDirectory /root/autodl-tmp/<project> `
  -Command "/root/miniconda3/bin/python -u <script>"
```

`ProjectName` is required and must be a filesystem-safe short name. `StartJob`
does not accept a caller-supplied `LogPath`; it always creates the canonical
remote path:

```text
/root/autodl-tmp/logs/<project>/YYYY/MM/DD/<UTC timestamp>_<session>_<run ID>.log
```

The UTC timestamp keeps paths sortable and unambiguous. The random run ID makes
repeated or simultaneous invocations unique without using the command or log
contents in the filename. Keep `LogPath` only for `JobStatus`, using the exact
path returned by `StartJob`.

Keep the actual workload in the foreground inside `screen`; do not add `&`,
`nohup`, or another session manager to `-Command`. The wrapper sets
`PYTHONUNBUFFERED=1`, but still prefer Python's `-u` option for immediately
visible training logs.

Capture the exact `__AUTODL_LOG_PATH__` returned by `StartJob`. Monitor without
disturbing the job:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\autodl-remote.ps1 `
  -Action JobStatus `
  -SessionName <session> `
  -LogPath <path-returned-by-StartJob> `
  -TailLines 100
```

The log contains `__AUTODL_JOB_EXIT_CODE__=<code>` only after the workload
finishes normally. If the instance is stopped or crashes, that footer may be
absent; diagnose with `screen -ls`, the log tail, `nvidia-smi`, and `ps`.

Stop a session or process only when the user explicitly asks, and target its exact name or PID.

## Finish the task

Report:

- whether passwordless connection succeeded;
- the remote working directory used;
- commands or transfers completed;
- project, run ID, background session, and log paths for long jobs;
- GPU/process status when relevant;
- any files or results the user should preserve before shutting down.

Never expose the private key, SSH password, access tokens, or unrelated remote secrets.
