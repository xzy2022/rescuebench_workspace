

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

其它关键的包见`manifests\rescue-nomad-runtime-requirements.txt`

### 准备 UE 资源

任何需要启动 RescueBench 仿真的测试，包括 random baseline，都需要 Unreal 二进制。官方 README 明确要求下载并设置 UnrealEnv。

```bash
# 下载 UE 资源
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

```

```bash
# 解压 UE 资源
PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"

ZIP_PATH=/root/autodl-fs/Rescue_Linux_v1.0.9.zip
UNREAL_ENV_DIR="$REPO/gym_rescue/envs/UnrealEnv"
FINAL_DIR="$UNREAL_ENV_DIR/Rescue_Linux"

test -f "$ZIP_PATH" || {
  echo "ZIP not found: $ZIP_PATH" >&2
  exit 1
}

mkdir -p "$UNREAL_ENV_DIR"

if [ -e "$FINAL_DIR" ] || [ -L "$FINAL_DIR" ]; then
  echo "Target already exists: $FINAL_DIR" >&2
  exit 1
fi

# ZIP 内部自带 Rescue_Linux_v1.0.9 顶层目录。先解压到临时目录，
# 验证结构后再将其改名为项目统一使用的 Rescue_Linux。
STAGE_DIR="$(mktemp -d "$UNREAL_ENV_DIR/.extract-rescue.XXXXXX")"
unzip "$ZIP_PATH" -d "$STAGE_DIR"

SOURCE_DIR="$STAGE_DIR/Rescue_Linux_v1.0.9"
SOURCE_BINARY="$SOURCE_DIR/Linux/Rescue/Binaries/Linux/Rescue"

test -f "$SOURCE_BINARY" || {
  echo "Unexpected ZIP layout: $SOURCE_BINARY not found" >&2
  exit 1
}

mv "$SOURCE_DIR" "$FINAL_DIR"
rmdir "$STAGE_DIR"

BINARY="$FINAL_DIR/Linux/Rescue/Binaries/Linux/Rescue"
chmod +x "$BINARY"
chmod +x "$FINAL_DIR/Linux/Rescue.sh"

test -x "$BINARY" && echo "UE binary ready: $BINARY"
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
# 因为 experiment.py 中写死了某个路径，并不适配我当前的云服务器路径
# 目前看这个和下面的功能相同，可以完全忽视它
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
