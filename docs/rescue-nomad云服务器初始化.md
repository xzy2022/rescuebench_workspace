

## nomad

### 镜像选择

nomad 
python 3.8.10
pytorch 2.0.0+cu118


Python       3.8.10
Torch        2.0.0+cu118
torchvision  0.15.1+cu118
CUDA         11.8
cuDNN        8.7
GPU          Tesla T4

### 拉取项目
```bash
# 工作空间项目
cd ~/autodl-tmp
git clone https://github.com/xzy2022/rescuebench_workspace.git

# RescueBench 项目
cd rescuebench_workspace/
mkdir repos/
cd repos/
git clone https://github.com/xzy2022/RescueBench.git

# 其它需要项目 这个是 nomad 的官方项目
git clone https://github.com/xzy2022/visualnav-transformer.git \
  /root/autodl-tmp/rescuebench_workspace/repos/visualnav-transformer
```

### 准备 conda 环境

```bash
# 克隆 conda 环境，避免破环 base 环境
source /root/miniconda3/etc/profile.d/conda.sh
export PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
export ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"
export CONDA_PKGS_DIRS="$PROJECT_ROOT/conda/pkgs"
export PIP_CACHE_DIR="$PROJECT_ROOT/cache/pip"

conda create -y \
  -p "$ENV_PATH" \
  --clone /root/miniconda3

"$ENV_PATH/bin/pip" install -e \
  /root/autodl-tmp/rescuebench_workspace/repos/RescueBench
```

### 准备 UE 资源

任何需要启动 RescueBench 仿真的测试，包括 random baseline，都需要 Unreal 二进制。官方 README 明确要求下载并设置 UnrealEnv。

```bash
PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
DOWNLOAD_DIR="$PROJECT_ROOT/assets/downloads"
ZIP_PATH="$DOWNLOAD_DIR/Rescue_Linux_v1.0.9.zip"

mkdir -p "$DOWNLOAD_DIR"
source /etc/network_turbo

curl -L --fail \
  --retry 8 \
  --retry-delay 5 \
  -C - \
  -o "$ZIP_PATH" \
  "https://huggingface.co/datasets/WuKui-buaa/RescueBench/resolve/main/Rescue_Linux_v1.0.9.zip"

PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

ZIP_PATH="$PROJECT_ROOT/assets/downloads/Rescue_Linux_v1.0.9.zip"
EXTRACT_ROOT="$PROJECT_ROOT/assets/unreal"
VERSION_DIR="$EXTRACT_ROOT/Rescue_Linux_v1.0.9"
UNREAL_ENV_DIR="$REPO/gym_rescue/envs/UnrealEnv"

mkdir -p "$EXTRACT_ROOT"
unzip "$ZIP_PATH" -d "$EXTRACT_ROOT"

mkdir -p "$UNREAL_ENV_DIR"
ln -s "$VERSION_DIR" "$UNREAL_ENV_DIR/Rescue_Linux"

BINARY="$UNREAL_ENV_DIR/Rescue_Linux/Linux/Rescue/Binaries/Linux/Rescue"
chmod +x "$BINARY"
chmod +x "$UNREAL_ENV_DIR/Rescue_Linux/Linux/Rescue.sh"
```

对于云服务器，UE需要额外设置,具体见`docs\UE两个报错解决.md`

之后启动项目必须使用

```bash
PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

cd "$REPO"
"$PROJECT_ROOT/bin/rescue-run" \
    "$ENV_PATH/bin/python" \
    benchmark/experiment.py \
    --model random \
    --levels 0 \
    --episodes 1 \
    --no-collision \
    --output "$PROJECT_ROOT/runs/random-baseline"

# experiment.py 有问题，则使用下面的
PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

cd "$REPO"

"$PROJECT_ROOT/bin/rescue-run" \
    "$ENV_PATH/bin/python" \
    benchmark/rescue_benchmark.py \
    --model random \
    --levels 0 \
    --episodes 1 \
    --no-collision \
    --output "$PROJECT_ROOT/runs/random-baseline"
```