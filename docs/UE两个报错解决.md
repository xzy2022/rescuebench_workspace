## 第一个问题

```bash
set -euo pipefail

PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

RUNNER_USER=rescue-runner
RUNNER_ROOT="$PROJECT_ROOT/runtime/$RUNNER_USER"
RUNNER_HOME="$RUNNER_ROOT/home"

UNREAL_ENV="$REPO/gym_rescue/envs/UnrealEnv"
UNREAL_LINK="$UNREAL_ENV/Rescue_Linux"
UE_ROOT="$(readlink -f "$UNREAL_LINK")"
UE_BIN_DIR="$UE_ROOT/Linux/Rescue/Binaries/Linux"
UE_BINARY="$UE_BIN_DIR/Rescue"

RUNNER_SCRIPT="$PROJECT_ROOT/bin/rescue-run"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this setup must be executed as root"
    exit 1
fi

test -d "$PROJECT_ROOT"
test -d "$REPO"
test -x "$ENV_PATH/bin/python"
test -x "$UE_BINARY"

# ACL 工具
if ! command -v setfacl >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y acl
fi

# 创建锁定、禁止交互登录的系统用户
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --user-group \
        --no-create-home \
        --home-dir "$RUNNER_HOME" \
        --shell /usr/sbin/nologin \
        "$RUNNER_USER"
fi

usermod \
    --home "$RUNNER_HOME" \
    --shell /usr/sbin/nologin \
    "$RUNNER_USER"

usermod -L "$RUNNER_USER"

if getent group video >/dev/null 2>&1; then
    usermod -aG video "$RUNNER_USER"
fi

# 独立 HOME、缓存和临时目录
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0700 \
    "$RUNNER_HOME" \
    "$RUNNER_ROOT/cache" \
    "$RUNNER_ROOT/config" \
    "$RUNNER_ROOT/data" \
    "$RUNNER_ROOT/tmp" \
    "$RUNNER_ROOT/xdg-runtime" \
    "$RUNNER_ROOT/pycache" \
    "$RUNNER_ROOT/torch" \
    "$RUNNER_ROOT/huggingface" \
    "$RUNNER_ROOT/matplotlib"

# benchmark 输出目录
mkdir -p \
    "$PROJECT_ROOT/bin" \
    "$PROJECT_ROOT/runs" \
    "$PROJECT_ROOT/outputs"

# /root 默认是 700，只给 rescue-runner 穿过权限
setfacl -m "u:${RUNNER_USER}:--x" /root

# 允许创建和更新实验输出
for writable_dir in \
    "$PROJECT_ROOT/runs" \
    "$PROJECT_ROOT/outputs"
do
    setfacl -R -m "u:${RUNNER_USER}:rwX" "$writable_dir"

    find "$writable_dir" -type d -exec \
        setfacl -m "d:u:${RUNNER_USER}:rwx" {} +
done

# UnrealCV 会在二进制旁读写 unrealcv.ini
setfacl -m "u:${RUNNER_USER}:rwx" "$UE_BIN_DIR"

if [ -f "$UE_BIN_DIR/unrealcv.ini" ]; then
    setfacl -m "u:${RUNNER_USER}:rw-" "$UE_BIN_DIR/unrealcv.ini"
fi

# UE 运行期间需要写 Saved/Logs、配置和崩溃日志
for ue_writable_dir in \
    "$UE_ROOT/Linux/Rescue/Saved" \
    "$UE_ROOT/Linux/Engine/Saved"
do
    if [ -d "$ue_writable_dir" ]; then
        setfacl -R -m "u:${RUNNER_USER}:rwX" "$ue_writable_dir"

        find "$ue_writable_dir" -type d -exec \
            setfacl -m "d:u:${RUNNER_USER}:rwx" {} +
    fi
done

# 创建 root 持有、普通用户不可修改的启动器
cat > "$RUNNER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

RUNNER_USER=rescue-runner
RUNNER_ROOT="$PROJECT_ROOT/runtime/$RUNNER_USER"
RUNNER_HOME="$RUNNER_ROOT/home"

UNREAL_ENV="$REPO/gym_rescue/envs/UnrealEnv"
HEADLESS_ICD=/etc/vulkan/icd.d/rescue_nvidia_headless.json

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: rescue-run must be called by root" >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 COMMAND [ARG ...]" >&2
    exit 2
fi

python_path="$REPO"

if [ -d "$PROJECT_ROOT/repos/visualnav-transformer" ]; then
    python_path="$python_path:$PROJECT_ROOT/repos/visualnav-transformer"
fi

runner_env=(
    "HOME=$RUNNER_HOME"
    "USER=$RUNNER_USER"
    "LOGNAME=$RUNNER_USER"
    "PROJECT_ROOT=$PROJECT_ROOT"
    "REPO=$REPO"
    "ENV_PATH=$ENV_PATH"
    "UnrealEnv=$UNREAL_ENV"
    "PATH=$ENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "PYTHONPATH=$python_path"
    "XDG_CACHE_HOME=$RUNNER_ROOT/cache"
    "XDG_CONFIG_HOME=$RUNNER_ROOT/config"
    "XDG_DATA_HOME=$RUNNER_ROOT/data"
    "XDG_RUNTIME_DIR=$RUNNER_ROOT/xdg-runtime"
    "TMPDIR=$RUNNER_ROOT/tmp"
    "PYTHONPYCACHEPREFIX=$RUNNER_ROOT/pycache"
    "TORCH_HOME=$RUNNER_ROOT/torch"
    "HF_HOME=$RUNNER_ROOT/huggingface"
    "MPLCONFIGDIR=$RUNNER_ROOT/matplotlib"
)

# RUN-002 配置完成后自动启用 headless Vulkan ICD
if [ -f "$HEADLESS_ICD" ]; then
    runner_env+=("VK_ICD_FILENAMES=$HEADLESS_ICD")
fi

exec /usr/sbin/runuser \
    -u "$RUNNER_USER" \
    -- \
    /usr/bin/env "${runner_env[@]}" "$@"
EOF

chown root:root "$RUNNER_SCRIPT"
chmod 0755 "$RUNNER_SCRIPT"

echo "RUN-001 setup complete"
```

## 第二个问题

```bash
(
set -euo pipefail

# ============================================================
# RUN-002：AutoDL 无桌面容器 Vulkan Loader + EGL ICD
# 已在 RTX 2080 Ti / NVIDIA 595.71.05 / Ubuntu 20.04 验证
# ============================================================

PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

RUNNER_USER=rescue-runner
RUNNER_ROOT="$PROJECT_ROOT/runtime/$RUNNER_USER"
RUNNER_HOME="$RUNNER_ROOT/home"

UNREAL_ENV="$REPO/gym_rescue/envs/UnrealEnv"
RUNNER_SCRIPT="$PROJECT_ROOT/bin/rescue-run"

VULKAN_VERSION=1.4.329
TOOLS_ROOT="$PROJECT_ROOT/tools"

HEADERS_SRC="$TOOLS_ROOT/vulkan-headers-$VULKAN_VERSION-src"
HEADERS_BUILD="$TOOLS_ROOT/vulkan-headers-$VULKAN_VERSION-build"

LOADER_SRC="$TOOLS_ROOT/vulkan-loader-$VULKAN_VERSION-src"
LOADER_BUILD="$TOOLS_ROOT/vulkan-loader-$VULKAN_VERSION-build"

VULKAN_PREFIX="$TOOLS_ROOT/vulkan-$VULKAN_VERSION"
VULKAN_LOADER_LIB="$VULKAN_PREFIX/lib"

SYSTEM_NVIDIA_ICD=/etc/vulkan/icd.d/nvidia_icd.json
HEADLESS_ICD=/etc/vulkan/icd.d/rescue_nvidia_headless.json
NVIDIA_EGL_LIB=/usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0

PYTHON_BIN="$ENV_PATH/bin/python"

test -x "$PYTHON_BIN"

# ------------------------------------------------------------
# 1. 前置检查
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this setup must be executed as root" >&2
    exit 1
fi

test -d "$PROJECT_ROOT"
test -d "$REPO"
test -x "$ENV_PATH/bin/python"
test -x "$NVIDIA_EGL_LIB"
test -f "$SYSTEM_NVIDIA_ICD"

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    echo "ERROR: $RUNNER_USER does not exist; run RUN-001 first" >&2
    exit 1
fi

mkdir -p \
    "$TOOLS_ROOT" \
    "$PROJECT_ROOT/bin" \
    "$PROJECT_ROOT/runs"

# ------------------------------------------------------------
# 2. 安装编译及验证依赖
# ------------------------------------------------------------

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends \
    git \
    gcc \
    pkg-config \
    vulkan-tools \
    libxcb1-dev \
    libx11-dev \
    libxrandr-dev \
    libwayland-dev

# Vulkan Loader 1.4.329 要求 CMake >= 3.22.1。
# 当前 RescueBench Conda 环境一般已经包含 CMake 3.26。
if [ -x "$ENV_PATH/bin/cmake" ]; then
    CMAKE="$ENV_PATH/bin/cmake"
elif [ -x /root/miniconda3/bin/cmake ]; then
    CMAKE=/root/miniconda3/bin/cmake
else
    "$ENV_PATH/bin/python" -m pip install "cmake==3.26.4"
    CMAKE="$ENV_PATH/bin/cmake"
fi

echo "Using CMake:"
"$CMAKE" --version | head -1

# ------------------------------------------------------------
# 3. 下载固定版本的 Vulkan-Headers
# ------------------------------------------------------------

if [ -d "$HEADERS_SRC/.git" ]; then
    HEADER_TAG="$(git -C "$HEADERS_SRC" describe --tags --exact-match 2>/dev/null || true)"

    if [ "$HEADER_TAG" != "v$VULKAN_VERSION" ]; then
        echo "ERROR: unexpected Vulkan-Headers checkout: $HEADER_TAG" >&2
        exit 1
    fi
elif [ -e "$HEADERS_SRC" ]; then
    echo "ERROR: path exists but is not a Git checkout: $HEADERS_SRC" >&2
    exit 1
else
    # 如果 GitHub 下载较慢，可在执行本段代码前启用：
    # source /etc/network_turbo
    git clone \
        --depth 1 \
        --branch "v$VULKAN_VERSION" \
        https://github.com/KhronosGroup/Vulkan-Headers.git \
        "$HEADERS_SRC"
fi

"$CMAKE" \
    -S "$HEADERS_SRC" \
    -B "$HEADERS_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$VULKAN_PREFIX"

"$CMAKE" --install "$HEADERS_BUILD"

# ------------------------------------------------------------
# 4. 下载并编译 Vulkan Loader 1.4.329
# ------------------------------------------------------------

if [ -d "$LOADER_SRC/.git" ]; then
    LOADER_TAG="$(git -C "$LOADER_SRC" describe --tags --exact-match 2>/dev/null || true)"

    if [ "$LOADER_TAG" != "v$VULKAN_VERSION" ]; then
        echo "ERROR: unexpected Vulkan-Loader checkout: $LOADER_TAG" >&2
        exit 1
    fi
elif [ -e "$LOADER_SRC" ]; then
    echo "ERROR: path exists but is not a Git checkout: $LOADER_SRC" >&2
    exit 1
else
    git clone \
        --depth 1 \
        --branch "v$VULKAN_VERSION" \
        https://github.com/KhronosGroup/Vulkan-Loader.git \
        "$LOADER_SRC"
fi

"$CMAKE" \
    -S "$LOADER_SRC" \
    -B "$LOADER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$VULKAN_PREFIX" \
    -DVulkanHeaders_DIR="$VULKAN_PREFIX/share/cmake/VulkanHeaders" \
    -DBUILD_TESTS=OFF \
    -DBUILD_WSI_XCB_SUPPORT=ON \
    -DBUILD_WSI_XLIB_SUPPORT=ON \
    -DBUILD_WSI_XLIB_XRANDR_SUPPORT=ON \
    -DBUILD_WSI_WAYLAND_SUPPORT=ON \
    -DBUILD_WSI_DIRECTFB_SUPPORT=OFF

"$CMAKE" --build "$LOADER_BUILD" --parallel 4
"$CMAKE" --install "$LOADER_BUILD"

test -e "$VULKAN_LOADER_LIB/libvulkan.so.1"

echo "Isolated Vulkan Loader:"
readlink -f "$VULKAN_LOADER_LIB/libvulkan.so.1"

# ------------------------------------------------------------
# 5. 创建 NVIDIA EGL Vulkan ICD
# ------------------------------------------------------------

# 使用项目 Conda 环境中的 Python。
PYTHON_BIN="$ENV_PATH/bin/python"
test -x "$PYTHON_BIN"

# 从 NVIDIA 原始 ICD 读取当前驱动声明的 Vulkan API 版本。
NVIDIA_API_VERSION="$(
    "$PYTHON_BIN" - "$SYSTEM_NVIDIA_ICD" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

print(data["ICD"]["api_version"])
PY
)"

echo "NVIDIA Vulkan API version: $NVIDIA_API_VERSION"

ICD_TMP="$(mktemp)"

cleanup() {
    rm -f "$ICD_TMP"
}

trap cleanup EXIT

cat > "$ICD_TMP" <<EOF
{
    "file_format_version": "1.0.1",
    "ICD": {
        "library_path": "$NVIDIA_EGL_LIB",
        "api_version": "$NVIDIA_API_VERSION"
    }
}
EOF

"$PYTHON_BIN" -m json.tool "$ICD_TMP" >/dev/null

install \
    -o root \
    -g root \
    -m 0644 \
    "$ICD_TMP" \
    "$HEADLESS_ICD"

echo "Headless Vulkan ICD:"
cat "$HEADLESS_ICD"

# ------------------------------------------------------------
# 6. 更新 rescue-run
# ------------------------------------------------------------

if [ -f "$RUNNER_SCRIPT" ]; then
    RUNNER_BACKUP="$PROJECT_ROOT/bin/rescue-run.before-run002-$(date +%Y%m%d-%H%M%S)"
    cp -a "$RUNNER_SCRIPT" "$RUNNER_BACKUP"
    echo "Original runner backup: $RUNNER_BACKUP"
fi

RUNNER_TMP="$(mktemp "$PROJECT_ROOT/bin/.rescue-run.XXXXXX")"

cat > "$RUNNER_TMP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=/root/autodl-tmp/rescuebench_workspace
REPO="$PROJECT_ROOT/repos/RescueBench"
ENV_PATH="$PROJECT_ROOT/conda/envs/rescue-nomad"

RUNNER_USER=rescue-runner
RUNNER_ROOT="$PROJECT_ROOT/runtime/$RUNNER_USER"
RUNNER_HOME="$RUNNER_ROOT/home"

UNREAL_ENV="$REPO/gym_rescue/envs/UnrealEnv"

HEADLESS_ICD=/etc/vulkan/icd.d/rescue_nvidia_headless.json
VULKAN_LOADER_LIB="$PROJECT_ROOT/tools/vulkan-1.4.329/lib"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: rescue-run must be called by root" >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 COMMAND [ARG ...]" >&2
    exit 2
fi

if [ ! -f "$HEADLESS_ICD" ]; then
    echo "ERROR: missing Vulkan ICD: $HEADLESS_ICD" >&2
    echo "Run the RUN-002 setup again." >&2
    exit 3
fi

if [ ! -e "$VULKAN_LOADER_LIB/libvulkan.so.1" ]; then
    echo "ERROR: missing isolated Vulkan Loader:" >&2
    echo "  $VULKAN_LOADER_LIB/libvulkan.so.1" >&2
    echo "Run the RUN-002 setup again." >&2
    exit 4
fi

python_path="$REPO"

if [ -d "$PROJECT_ROOT/repos/visualnav-transformer" ]; then
    python_path="$python_path:$PROJECT_ROOT/repos/visualnav-transformer"
fi

runner_env=(
    "HOME=$RUNNER_HOME"
    "USER=$RUNNER_USER"
    "LOGNAME=$RUNNER_USER"

    "PROJECT_ROOT=$PROJECT_ROOT"
    "REPO=$REPO"
    "ENV_PATH=$ENV_PATH"
    "UnrealEnv=$UNREAL_ENV"

    "PATH=$ENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "PYTHONPATH=$python_path"

    # RUN-002：使用项目目录中的新版 Vulkan Loader
    "LD_LIBRARY_PATH=$VULKAN_LOADER_LIB"

    # RUN-002：无桌面环境使用 NVIDIA EGL ICD
    "VK_ICD_FILENAMES=$HEADLESS_ICD"

    "XDG_CACHE_HOME=$RUNNER_ROOT/cache"
    "XDG_CONFIG_HOME=$RUNNER_ROOT/config"
    "XDG_DATA_HOME=$RUNNER_ROOT/data"
    "XDG_RUNTIME_DIR=$RUNNER_ROOT/xdg-runtime"
    "TMPDIR=$RUNNER_ROOT/tmp"

    "PYTHONPYCACHEPREFIX=$RUNNER_ROOT/pycache"
    "TORCH_HOME=$RUNNER_ROOT/torch"
    "HF_HOME=$RUNNER_ROOT/huggingface"
    "MPLCONFIGDIR=$RUNNER_ROOT/matplotlib"
)

exec /usr/sbin/runuser \
    -u "$RUNNER_USER" \
    -- \
    /usr/bin/env "${runner_env[@]}" "$@"
EOF

bash -n "$RUNNER_TMP"

install \
    -o root \
    -g root \
    -m 0755 \
    "$RUNNER_TMP" \
    "$RUNNER_SCRIPT"

rm -f "$RUNNER_TMP"

# ------------------------------------------------------------
# 7. 验证启动器环境
# ------------------------------------------------------------

ENV_LOG="$PROJECT_ROOT/runs/rescue-run-env.txt"

"$RUNNER_SCRIPT" /usr/bin/env >"$ENV_LOG" 2>&1

grep '^USER=rescue-runner$' "$ENV_LOG"
grep "^LD_LIBRARY_PATH=$VULKAN_LOADER_LIB$" "$ENV_LOG"
grep "^VK_ICD_FILENAMES=$HEADLESS_ICD$" "$ENV_LOG"

# ------------------------------------------------------------
# 8. 验证 Vulkan
# ------------------------------------------------------------

VULKAN_LOG="$PROJECT_ROOT/runs/vulkaninfo-$(date +%Y%m%d-%H%M%S).txt"

"$RUNNER_SCRIPT" /usr/bin/vulkaninfo >"$VULKAN_LOG" 2>&1

echo
echo "RUN-002 setup complete"
echo "Vulkan log: $VULKAN_LOG"
echo

grep -E -m 20 \
    'GPU id|deviceName|apiVersion|driverName|driverInfo' \
    "$VULKAN_LOG"

)
```
