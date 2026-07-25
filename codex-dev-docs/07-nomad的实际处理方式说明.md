

## 官方做法

### 下半程担架图像缺失的处理

当前 vint_agent.py 的行为是：
semantic_goal = self._get_semantic_goal_pil(info)
goal_image = semantic_goal if semantic_goal is not None else obs_image
也就是说：
找到担架图：以担架图作为 goal_img；
找不到：把当前摄像头画面作为自己的目标图；

当前代码似乎是在第一次测试时发现缺少担架图，于是第二次测试就先让机器人去担架附近拍摄担架图并保存。

