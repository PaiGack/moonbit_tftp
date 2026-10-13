# 路线图

按可独立提交、可独立验证的顺序拆分，每步都应有对应的测试。

## M0 骨架（已完成）

- [x] `moon new` 初始化模块，确定包名与元数据
- [x] 协议层最小公开 API：opcode、默认块大小、默认端口
- [x] 双仓 CI 骨架（CNB 流水线 + GitHub Actions）
- [x] 文档：协议速览 / 架构 / 路线图 / 参考实现

## M1 报文层

- [x] 报文字节编解码：RRQ / WRQ / DATA / ACK / ERROR / OACK（`encode` / `decode`）
- [x] 往返测试 + 畸形报文（截断、非法 opcode、超长字段、缺 `\0`）处理
- [x] 通道模式枚举：netascii / octet（mail 只留枚举值，`decode` 拒绝）
- [x] 选项 `Option\0Value\0` 拆分（取值校验留给 M2）

## M2 选项协商（已完成）

- [x] 解析 `Option\0Value\0` 序列
- [x] `blksize` / `timeout` / `tsize` 的取值校验与缺省回退
- [x] 服务端 OACK 生成与拒绝路径（ERROR 8）

## M3 客户端（已完成）

- [x] 传输抽象与内存实现（便于离线测试）
- [x] `get` / `put` 停等状态机
- [x] 超时重传 + 重复包去重（Sorcerer's Apprentice）
- [x] block 号 u16 回绕
- [x] netascii 转换

## M4 服务端

- [ ] 69 端口请求接收与 TID 会话分发
- [ ] 并发会话生命周期管理
- [ ] 根目录约束与路径穿越防护
- [ ] 错误码语义（文件不存在 / 访问违规 / 磁盘满 …）

## M5 CLI 与收尾

- [ ] `cmd/main`：`get` / `put` / `serve` 子命令
- [ ] 端到端示例与 README 补全
- [ ] 覆盖率检查与边界用例补齐

## 待定

- DHCP / BOOTP 组合（作为「网络引导工具链」的可选扩展）
- 平台支持矩阵细化（native 为主，js / wasm 视 socket 能力而定）
