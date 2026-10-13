# PaiGack/tftp

TFTP（Trivial File Transfer Protocol，简单文件传输协议）的纯 MoonBit 实现，
覆盖 RFC 1350 基础协议与 RFC 2347/2348/2349 的选项扩展。

- 上游仓库：<https://github.com/PaiGack/moonbit_tftp>
- 包名：`PaiGack/tftp`
- 许可证：Apache-2.0

## 目标

做成一个「协议库 + 客户端 + 服务端」的完整实现，两端共享报文编解码层：

- **报文层**：RRQ / WRQ / DATA / ACK / ERROR / OACK 的编解码（`encode` / `decode`），
  通道模式（netascii / octet），畸形报文以 `DecodeError` 返回，block 号 u16 回绕。
- **客户端**：`get` / `put`，超时重传、重复包去重（Sorcerer's Apprentice 问题修复）、
  blksize / timeout / tsize 选项协商。
- **服务端**：69 端口监听、每请求独立 TID 会话、并发会话管理、
  读写权限与路径穿越防护、错误码语义。
- **CLI**：`cmd/main` 提供命令行入口。

## 当前状态

报文层与选项协商已落地，都是纯函数、无 socket 依赖，可离线测试：

- 六种报文的编解码、通道模式枚举、错误码枚举与畸形报文处理；
- RFC 2347 选项协商：`blksize` / `timeout` / `tsize` 的解析与取值校验、
  OACK 生成、拒绝路径（ERROR code 8）。

客户端 / 服务端在后续提交中逐步落地，详见 [docs/roadmap.md](docs/roadmap.md)。

## 使用

```bash
moon check          # 类型检查
moon test           # 运行测试（默认全后端）
moon run cmd/main   # 运行 CLI 骨架
moon fmt            # 格式化
```

## 文档

- [docs/protocol.md](docs/protocol.md) —— TFTP 协议速览
- [docs/architecture.md](docs/architecture.md) —— 包结构与设计
- [docs/roadmap.md](docs/roadmap.md) —— 功能拆解与里程碑
- [docs/references.md](docs/references.md) —— 参考实现与许可证
- [docs/proposal.md](docs/proposal.md) —— 项目申报书

## 平台支持

TFTP 基于 UDP，需要宿主提供 UDP socket。规划中的主目标是 `native`；
`js`/`wasm` 后端受限于沙箱的 socket 能力，以实现进度为准。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
