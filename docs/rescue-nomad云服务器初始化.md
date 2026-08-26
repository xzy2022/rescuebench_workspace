

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

# 其它需要项目
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
