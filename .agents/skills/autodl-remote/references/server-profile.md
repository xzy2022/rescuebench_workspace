# AutoDL server profile

## Connection

- SSH alias: `autodl-t4`
- Project SSH config: `<project-root>\autodl-ssh.config`
- Human interactive command: `ssh -F <project-root>\autodl-ssh.config autodl-t4`
- Authentication: dedicated local ED25519 key referenced by the project SSH config
- Source of truth for endpoint, port, user, and key path: `ssh -F <project-root>\autodl-ssh.config -G autodl-t4`

Do not duplicate the private key contents or password in the project. Treat hostname and port as changeable and update them from the current AutoDL console SSH command.

## Stable working conventions

- Instance-local high-speed data disk: `/root/autodl-tmp`
- Cross-instance file storage for important results: `/root/autodl-fs` when available
- Shared public data: `/root/autodl-pub` (read-only)
- System disk: `/root`; keep large projects and experiment outputs off this smaller disk
- Base Python: `/root/miniconda3/bin/python`
- Base Conda: `/root/miniconda3/bin/conda`
- TensorBoard log directory: `/root/tf-logs`
- Run log root: `/root/autodl-tmp/logs`
- Long-running jobs: named `screen` sessions with redirected logs

Use `/root/autodl-tmp` for active projects, environments, datasets, checkpoints, caches, and outputs. It is fast instance-local storage, not a cross-instance backup. Copy important results, manifests, environment records, and final checkpoints to `/root/autodl-fs` when that storage is mounted, and keep another external backup for irreplaceable data.

`StartJob` stores stdout/stderr logs under the stable run-log root using:

```text
/root/autodl-tmp/logs/<project>/YYYY/MM/DD/<UTC timestamp>_<session>_<run ID>.log
```

Treat this root as the source of truth for future pre-shutdown inventory and
local archival. Do not scatter managed run logs inside individual project
directories.

Suggested layout:

```text
/root/autodl-tmp/
└──  projects/
```

Do not store a fixed hardware or software snapshot in this profile. Instances can change. Run `Probe` and inspect its output before relying on the GPU, driver, CUDA toolkit, OS, Python, PyTorch, Conda environments, job tools, mounted storage, or existing project directories. `nvidia-smi`, `nvcc`, and `torch.version.cuda` describe different CUDA layers and should be interpreted separately.

## Common read-only checks

```bash
cat /etc/os-release
nvidia-smi
command -v nvcc >/dev/null && nvcc --version
df -hT / /root/autodl-tmp
test -d /root/autodl-fs && df -hT /root/autodl-fs
/root/miniconda3/bin/conda env list
/root/miniconda3/bin/python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
command -v screen || true
command -v tmux || true
screen -ls
find /root/autodl-tmp -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
ps -eo pid,ppid,%cpu,%mem,etime,cmd --sort=-%cpu | head -20
```

## Service access

Prefer SSH tunnels for development services that are not exposed by the AutoDL control panel:

```powershell
ssh -F <project-root>\autodl-ssh.config -L <local-port>:127.0.0.1:<remote-port> autodl-t4
```

AutoDL commonly maps selected service ports through its control panel. Verify current mappings there rather than assuming a public endpoint.

## Data and cost reminders

- Back up important results outside the instance-local disks; `/root/autodl-tmp` is not a cross-instance backup.
- Use `/root/autodl-fs` for important cross-instance copies when it is available, but keep an additional external backup for irreplaceable data.
- Stop paid compute when it is no longer needed.
- Preserve checkpoints, logs, metrics, configuration, and exact dependency versions before shutdown or migration.
