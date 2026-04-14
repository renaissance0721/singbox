# 贡献指南

感谢你愿意改进 `singbox`。这个项目目前以 Bash 脚本为主，欢迎提交 bug 修复、文档优化、协议支持改进和可维护性增强。

## 提交前建议

1. 先查看仓库中的现有 [Issues](https://github.com/renaissance0721/singbox/issues)。
2. 若你准备实现较大的改动，建议先开一个 Issue 说明目标和思路。
3. 修改行为、命令或默认值时，请同步更新 `README.md` 和 `CHANGELOG.md`。

## 本地开发流程

```bash
git clone https://github.com/renaissance0721/singbox.git
cd singbox
git checkout -b feature/your-change
```

## 代码风格

- 保持 Bash 写法清晰、保守，优先可读性
- 尽量复用已有函数和交互风格
- 新增注释时解释“为什么”，而不是重复代码本身
- 新增命令入口时，同时更新帮助文案

## 最低检查项

提交 Pull Request 之前，至少请完成下面几项：

```bash
bash index.sh --help
bash index.sh --version
bash -n index.sh
shellcheck index.sh
```

如果你的改动影响运行逻辑，也请在真实 Linux 环境中补充手工验证，例如：

- 首次安装流程是否可完成
- 三种协议能否正常启用和生成配置
- 客户端新增、删除、导出是否符合预期
- `apply`、`overview`、`status` 是否输出正常

## Pull Request 说明建议

提交 PR 时请尽量包含：

- 改动目的
- 影响范围
- 测试方式
- 是否涉及破坏性变更

## 文档与非代码贡献

下面这些改动同样非常欢迎：

- 改进安装说明
- 增补发行版兼容性说明
- 修正文案、拼写或格式问题
- 提供更完整的故障排查信息

## 安全问题

如果发现敏感安全问题，请不要直接公开提交。请先阅读 [SECURITY.md](SECURITY.md)。
