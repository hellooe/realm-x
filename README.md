# Realm 管理工具集

一套便捷的 **Realm** 端口转发管理脚本 + Web 配置生成器，支持一键安装、更新、卸载、动态添加/删除转发规则，并提供了友好的可视化界面生成命令。

---

## ✨ 功能特性

- **原子性规则添加**：添加规则时先校验所有规则有效性，全部通过后才写入配置文件，避免数据不一致。
- **远程连通性检测**：添加规则时自动测试 TCP 连通性，批量添加仅警告，交互式添加可选是否继续。
- **连通性批量测试**：交互式菜单提供“测试所有远程连通性”功能，快速排查不可达地址。
- **负载均衡支持**：支持 `roundrobin` 和 `iphash` 策略，权重可自定义。
- **Web 配置生成器**：图形化界面，生成可直接执行的 shell 命令，批量添加/删除规则。
- **多 init 系统兼容**：自动检测 `Systemd` 或 `OpenRC`，无缝适配主流 Linux 发行版。

---

## 🚀 快速开始

### 1. 安装 Realm

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hellooe/realm-x/refs/heads/master/xm.sh)
```

进入交互式菜单，选择 `1` 即可。

```
===== Realm 管理菜单 =====
1. 安装 Realm
2. 更新 Realm
3. 卸载 Realm
4. 查看规则
5. 添加规则
6. 删除规则
7. 测试所有远程连通性
0. 退出
```

---

### 2. 命令行模式（非交互）

```bash
# 安装
XM_ACTION=install bash <(curl -Ls https://raw.githubusercontent.com/hellooe/realm-x/refs/heads/master/xm.sh)

# 更新
XM_ACTION=update bash <(curl -Ls https://raw.githubusercontent.com/hellooe/realm-x/refs/heads/master/xm.sh)

# 卸载
XM_ACTION=uninstall bash <(curl -Ls https://raw.githubusercontent.com/hellooe/realm-x/refs/heads/master/xm.sh)

# 添加规则（需配合 XM_ADD_JSON）
XM_ACTION=add XM_CLEAR=true ENABLE_TCP=true ENABLE_UDP=true XM_ADD_JSON='[{"listen":"0.0.0.0:10000","remote":"127.0.0.1:20000"}]' bash <(curl -Ls ...)

# 删除规则
XM_ACTION=delete XM_DELETE_PORT="10001,10002,20001-20002" bash <(curl -Ls ...)
```

## 📝 环境变量说明

| 变量名 | 用途 | 取值示例 |
|--------|------|----------|
| `XM_ACTION` | 操作类型 | `install` / `update` / `uninstall` / `add` / `delete` |
| `XM_ADD_JSON` | 添加规则（JSON 数组） | `'[{"listen":"0.0.0.0:10000","remote":"127.0.0.1:20000","extra_remotes":["1.2.3.4:80"],"balance":"roundrobin: 4,2,1"}]'` |
| `XM_CLEAR` | 添加前是否清空现有规则 | `true` 或 `false` |
| `XM_DELETE_PORT` | 要删除的端口（支持逗号和范围） | `10001,10002,20001-20002` |
| `ENABLE_TCP` | 启用 TCP 转发 | `true` / `false` |
| `ENABLE_UDP` | 启用 UDP 转发 | `true` / `false` |

> **注意**：当 `ENABLE_TCP=false` 时，连通性测试会被跳过。

---

## 📄 许可证

本项目基于 MIT 许可证开源，详情见 [LICENSE](LICENSE) 文件。

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。如果你有改进建议或发现 bug，请随时联系。