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

## M4 服务端（已完成）

- [x] 69 端口请求接收与 TID 会话分发（`Dispatcher` + `TidAllocator`）
- [x] 并发会话生命周期管理（每会话独立 TID，`step_write` 不主动发送，
      调用方掌握时序）
- [x] 根目录约束与路径穿越防护（`resolve_path`，拒绝 `..`）
- [x] 错误码语义（文件不存在 1 / 访问违规 2 / 磁盘满 3 / 非法操作 4 /
      已存在 6 / 协商失败 8 / 超时 0）

## M5 CLI 与收尾（已完成）

- [x] `cmd/main`：`get` / `put` / `serve` 子命令
- [x] 真实 UDP 套接字上的客户端传输（`transport_socket.mbt`），并让服务端
      会话传输实现 `Transport`（`server_fs.mbt`），使 CLI 复用库的状态机
- [x] 端到端示例与 README 补全（用法、平台支持矩阵）
- [x] 覆盖率检查与边界用例补齐（`scripts/ci.sh` 用 `moon coverage report -f summary` 汇总，见下）
- [x] 与 curl 的互操作对拍，并据此修复两个真实对端才暴露的问题
      （见 `docs/interop.md`）
- [x] roadmap 里 M0~M5 的勾选框回填

### 覆盖率

CI 用 `moon coverage report -f summary` 打印汇总，不设门槛也不留
`uncovered.log`：覆盖率是给人看的，不是卡构建的。当前合计
`1168/1368`（`server_fs.mbt` 由 `server_fs_wbtest.mbt` 覆盖）。

## 待定

- DHCP / BOOTP 组合（作为「网络引导工具链」的可选扩展）
- 与 tftp-hpa / atftp 的对拍（环境暂无这两个程序）
- 平台支持矩阵细化（native 为主，js / wasm 视 socket 能力而定）
