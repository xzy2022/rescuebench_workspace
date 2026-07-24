# AutoDL server profile

## Connection

- SSH alias: `autodl-t4`
- Human interactive command: `ssh autodl-t4`
- Authentication: dedicated local ED25519 key through `~/.ssh/config`
- Source of truth for endpoint, port, user, and key path: `ssh -G autodl-t4`

Do not duplicate the private key or password in the project. Treat hostname and port as changeable and resolve them from the alias.

## Stable working conventions

- Persistent research data: `/root/autodl-tmp`
- Shared public data: `/root/autodl-pub` (read-only)
- Base Python: `/root/miniconda3/bin/python`
- Base Conda: `/root/miniconda3/bin/conda`
- TensorBoard log directory: `/root/tf-logs`
- Run log root: `/root/autodl-tmp/logs`
- Long-running jobs: named `screen` sessions with redirected logs

Keep projects, environments, datasets, checkpoints, and outputs under `/root/autodl-tmp` to avoid filling the smaller system disk.

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
├── projects/
├── datasets/
├── envs/
├── checkpoints/
└── outputs/
```

## Last observed hardware and base environment

Treat these as observations, not permanent guarantees. Re-run `Probe` before relying on them.

- GPU: NVIDIA Tesla T4, 16 GiB
- Data disk: 50 GB at `/root/autodl-tmp`
- OS: Ubuntu 20.04
- Python: 3.8.10
- PyTorch: 2.0.0+cu118
- CUDA toolkit: 11.8
- `screen`: installed
- `tmux`: not installed

`nvidia-smi` may display a newer CUDA compatibility version than the toolkit used by PyTorch. Check `torch.version.cuda` when framework compatibility matters.

## Common read-only checks

```bash
nvidia-smi
df -hT /root/autodl-tmp
du -sh /root/autodl-tmp/* 2>/dev/null | sort -h
/root/miniconda3/bin/conda env list
/root/miniconda3/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
screen -ls
ps -eo pid,ppid,%cpu,%mem,etime,cmd --sort=-%cpu | head -20
```

## Service access

Prefer SSH tunnels for development services that are not exposed by the AutoDL control panel:

```powershell
ssh -L <local-port>:127.0.0.1:<remote-port> autodl-t4
```

AutoDL commonly maps selected service ports through its control panel. Verify current mappings there rather than assuming a public endpoint.

## Data and cost reminders

- Back up important results outside the instance; local instance disks are not a backup.
- Stop paid compute when it is no longer needed.
- Preserve checkpoints, logs, metrics, configuration, and exact dependency versions before shutdown or migration.
