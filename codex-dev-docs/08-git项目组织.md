

## 工作空间项目

1. 把当前的项目发布到github，名称为`rescuebench_workspace`
2. 当前项目下面创建`repos/`子文件夹，并保持忽略
3. `repos/RescueBench` 和 `repos/visualnav-transformer` 这些需要的项目，我会拉取到本地对应的文件夹，分别各自作为 github 项目管理，而不作为 `rescuebench_workspace` 的子项目。
4. 如果 `repos/` 下的项目需要修改，那我会 fork 一个，然后修改，然后推送到自己 fork 的项目。如果不需要修改，我就直接 clone 原项目。


之后我会参考`codex-dev-docs\01-文件组织路径推荐.md`并对其进行修改：
1. 在服务器上，分别拉取 `rescuebench_workspace` 和 `repos/` 下的项目
2. 其它的重资产和 conda 环境这些的存储位置再说。