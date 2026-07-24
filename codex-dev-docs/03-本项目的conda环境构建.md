

RescueBench 与 NoMaD 应当合在一个环境。当前 RescueBench 不是通过独立服务调用 NoMaD，而是在同一个 Python 进程中直接执行

```
Conda Base：
/root/miniconda3

Python：
/root/miniconda3/bin/python

Torch：
/root/miniconda3/lib/python3.8/site-packages/torch

torchvision：
/root/miniconda3/lib/python3.8/site-packages/torchvision
```

克隆base环境到专有环境。
```bash
source /root/miniconda3/etc/profile.d/conda.sh

export PROJECT_ROOT=/root/autodl-tmp/rescue-nomad
export ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"
export CONDA_PKGS_DIRS="$PROJECT_ROOT/conda/pkgs"
export PIP_CACHE_DIR="$PROJECT_ROOT/cache/pip"

conda create -y \
  -p "$ENV_PATH" \
  --clone /root/miniconda3
```