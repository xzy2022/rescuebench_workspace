# 本项目 Conda 环境依赖安装记录

ID：DEP-001：ROS 消息依赖
- 问题：`visualnav-transformer/deployment/src/utils.py` 顶层导入 `sensor_msgs.msg.Image`，未安装 ROS 时会阻断 RescueBench 加载 NoMaD。
- 分析：RescueBench 只使用 `load_model`、`transform_images` 和 `to_numpy`；ROS 消息只用于官方机器人部署，不参与 Unreal 测评。
- 解决：在分支 `codex/rescuebench-compat` 将 `sensor_msgs` 改为可选导入，并在真正调用 ROS 转换时明确报错。提交为 `df0cffb`；服务器不安装 ROS 或 `sensor_msgs`。
- 可能风险：官方 `navigate.py`、`explore.py`、`create_topomap.py` 和 `joy_teleop.py` 仍需完整 ROS 环境；运行测评时必须包含上述兼容提交。


ID：DEP-002：ViT 与 einops 版本
- 问题：NoMaD 导入链因缺少 `vit_pytorch` 失败；发布时期的 `vit-pytorch 1.6.3` 要求 `einops>=0.7.0`，与最初参考 diffusion_policy 环境安装的 `einops 0.4.1` 不兼容。
- 分析：`einops 0.4.1` 只是 diffusion_policy 旧环境版本，并非 NoMaD 的强制版本。visualnav-transformer 会顶层导入 ViT，因此即使运行 NoMaD也需要满足 ViT 的导入依赖。
- 解决：安装 `vit-pytorch==1.6.3`，将 `einops` 升级到 `0.7.0`。真实 NoMaD 导入、DDPM调度器、Conditional U-Net前向和 `get_action` 测试均通过。
- 可能风险：`einops 0.7.0` 高于 diffusion_policy 原环境版本；当前使用的张量变换接口向后兼容且测试通过，后续必须在环境清单中固定这两个版本。
