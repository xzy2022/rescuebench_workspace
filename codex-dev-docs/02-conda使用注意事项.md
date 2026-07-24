# AutoDL Conda 使用注意事项

## 1. 不要改动系统 Base

AutoDL 通常将 Conda 和 Base 环境放在`/root/miniconda3`：

不要移动、删除或直接向 Base 安装项目依赖，也不要随意执行。
如果需要base环境中的pytorch等包，可以通过克隆的方式克隆到新建环境。

## 2. 环境和缓存放数据盘

```bash
export PROJECT_ROOT=/root/autodl-tmp/my-project
export ENV_PATH="$PROJECT_ROOT/conda/envs/main"
export CONDA_PKGS_DIRS="$PROJECT_ROOT/conda/pkgs"
export PIP_CACHE_DIR="$PROJECT_ROOT/cache/pip"

mkdir -p "$PROJECT_ROOT/conda/envs" "$CONDA_PKGS_DIRS" "$PIP_CACHE_DIR"
conda create -y -p "$ENV_PATH" python=3.8.10
```
`-p` 指定完整环境路径，不需要修改全局 `.condarc`。两个缓存变量只对当前 Shell 生效。

## 3. 使用完整路径激活和运行

```bash
source /root/miniconda3/etc/profile.d/conda.sh
export ENV_PATH=/root/autodl-tmp/my-project/conda/envs/main

conda activate "$ENV_PATH"
```

自动化脚本优先使用：

```bash
conda run -p "$ENV_PATH" python your_script.py
```

确认没有误用 Base。

