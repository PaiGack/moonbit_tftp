# PaiGack/tftp

TFTP（Trivial File Transfer Protocol，简单文件传输协议）的纯 MoonBit 实现，
覆盖 RFC 1350 基础协议与 RFC 2347/2348/2349 的选项扩展。

- 上游仓库：<https://github.com/PaiGack/moonbit_tftp>
- 包名：`PaiGack/tftp`
- 许可证：Apache-2.0

## 目标

做成一个「协议库 + 客户端 + 服务端 + 命令行」的完整实现，各层共享报文编解码：

- **报文层**：RRQ / WRQ / DATA / ACK / ERROR / OACK 的编解码（`encode` / `decode`），
  通道模式（netascii / octet），畸形报文以 `DecodeError` 返回，block 号 u16 回绕。
- **客户端**：`get` / `put`，超时重传、重复包去重（Sorcerer's Apprentice 问题修复）、
  blksize / timeout / tsize 选项协商。
- **服务端**：69 端口监听、每请求独立 TID 会话、并发会话管理、
  读写权限与路径穿越防护、错误码语义。
- **CLI**：`cmd/main` 的 `get` / `put` / `serve` 三个子命令。

## 当前状态

M0~M5 已落地：报文层、选项协商、客户端、服务端与命令行全部可用，
`moon test` 覆盖到内存传输上的完整会话，CLI 已在真实 UDP 套接字上跑通
（见下方示例）。

## 快速开始

```bash
moon check          # 类型检查
moon test           # 运行测试
moon fmt            # 格式化
moon info           # 更新 .mbti 接口
```

## 命令行

构建后 `cmd/main` 是一个可执行程序，三个子命令覆盖日常用法。

### 服务端

```bash
# 在 6969 端口把 ./tftpboot 目录（含子目录）发布出去，允许覆盖已有文件
moon run cmd/main -- serve --root ./tftpboot --port 6969 --allow-overwrite
```

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--root DIR` | 对外服务的根目录，请求路径被限制在其中 | `.` |
| `--port N` | 监听的 UDP 端口 | `69` |
| `--allow-overwrite` | 允许 WRQ 覆盖已存在的文件 | 关闭（仅新建） |
| `--max-sessions N` | 并发会话上限，超出的请求回 ERROR 4 且不建立会话 | `32` |

### 下载（get）

```bash
# 把服务器上的 boot.img 下载到本地同名文件
moon run cmd/main -- get 192.168.1.10:69 boot.img

# 指定本地落盘路径，并协商 1428 字节块
moon run cmd/main -- get 192.168.1.10:69 boot.img ./downloads/boot.img --blksize 1428

# 文本文件用 netascii 模式
moon run cmd/main -- get 192.168.1.10:69 config.txt --netascii
```

### 上传（put）

```bash
# 第三个位置参数省略时，远端沿用本地文件名
moon run cmd/main -- put 192.168.1.10:69 ./boot.img

# 显式指定远端文件名
moon run cmd/main -- put 192.168.1.10:69 ./boot.img remote/boot.img
```

`get` / `put` 共用以下参数：

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--blksize N` | 协商的块大小（8~65464） | `512` |
| `--timeout N` | 单包超时（秒） | `5` |
| `--retries N` | 放弃前的重传次数 | `6` |
| `--netascii` | 使用 netascii 模式（默认 octet） | 关闭 |

退出码：`0` 成功；`1` 传输失败（对端报错 / 超时 / 本地读写失败）；
`2` 命令行用法错误。

### 进度与容量校验

`put` / `get` 在协商到 `tsize` 时会按整百分比打印进度行，块与块之间不刷屏：

```
boot.img: 12% (30720/262144 bytes)
boot.img: 24% (61440/262144 bytes)
```

`put` 还会做容量校验：对端在 OACK 里确认的 `tsize` 必须等于本地实际发送的
字节数，不一致就以非 0 退出并报 `capacity check failed`——停等协议没有别的
方式报告对端只收下了一部分。对端不协商 `tsize`（选项可选）时不校验。

### 本机对拍

一条命令就能在本机验证 put 与 get 的双向正确性：

```bash
# 终端 A
moon run cmd/main -- serve --root /tmp/tftproot --port 6969 --allow-overwrite

# 终端 B
moon run cmd/main -- put 127.0.0.1:6969 ./big.bin            # 上传
moon run cmd/main -- get 127.0.0.1:6969 big.bin ./got.bin    # 下载回来
cmp ./big.bin ./got.bin && echo "byte-for-byte identical"
```

## 作为库使用

传输由调用方注入，既可以是真实套接字，也可以是内存实现：

```moonbit nocheck
///|
async fn download() -> Unit {
  let transport = @tftp.SocketTransport::new("192.168.1.10:69")
  defer transport.close()
  match
    @tftp.get(
      transport,
      "192.168.1.10:69",
      "boot.img",
      @tftp.ClientOptions::default(),
    ) {
    Ok(outcome) =>
      match outcome.received() {
        Some(bytes) => println("got \{bytes.length()} bytes")
        None => ()
      }
    Err(_) => println("transfer failed")
  }
}
```

## 平台支持

TFTP 基于 UDP，需要宿主提供 UDP socket。当前只有 `native` 是可端到端跑通的
目标，其余后端的编译结果按「包 / 目标」分开看，与 `moon check --target <t>` 一致：

### 根包 `PaiGack/tftp`（协议层 + 状态机 + socket 后端）

报文编解码、选项协商、netascii 与两个状态机都是纯函数或纯状态转移，不依赖
socket；socket 后端（`server_fs.mbt`、`transport_socket.mbt`）依赖
`mizchi/x` 的 `socket` / `fs` 实现。

| 目标 | check 结果 | 说明 |
| --- | --- | --- |
| `native` | ✅ 通过 | CI 全流程（check / test / build）在 native 上跑 |
| `js` | ✅ 通过 | 依赖 `mizchi/x` 在 js 上提供的 socket / fs 替身，可编译；未做端到端验证 |
| `wasm` | ✅ 通过 | 同上 |
| `wasm-gc` | ❌ 编译失败 | `mizchi/x` 的 `socket` 替身在 wasm-gc 上缺少 `.addr` 字段 |

`wasm-gc` 的失败点（均为 `The type ... has no field 'addr'`，error 4091）：

- `server_fs.mbt:141`、`server_fs.mbt:175` —— `UdpClient.addr`
- `transport_socket.mbt:38` —— `UdpServer.addr`
- 对应 `server_fs_wbtest.mbt`、`transport_socket_wbtest.mbt` 中的同类调用

### CLI `cmd/main`

CLI 是 `executable`，用 `extern "C" fn exit` 退出进程，非 native 后端不支持
`extern "C"`。

| 目标 | check 结果 | 说明 |
| --- | --- | --- |
| `native` | ✅ 通过 | `scripts/ci.sh` 的 CLI 演示在真实 UDP 套接字上跑通 |
| `js` | ❌ 编译失败 | `cmd/main/main.mbt:53` 的 `extern "C" fn exit`（error 4156） |
| `wasm` | ❌ 编译失败 | 同上 |
| `wasm-gc` | ❌ 编译失败 | `extern "C" fn exit`，并叠加根包在 wasm-gc 上的 `.addr` 报错 |

> 结论：`moon check` 的失败源在「CLI 的 `extern "C"`（js / wasm）」与
> 「`mizchi/x` socket 在 wasm-gc 上缺 `.addr`（根包 + CLI）」两处，
> 与协议层本身无关。除 `native` 外都还没做端到端验证。

## 文档

- [docs/protocol.md](docs/protocol.md) —— TFTP 协议速览
- [docs/architecture.md](docs/architecture.md) —— 包结构与设计
- [docs/roadmap.md](docs/roadmap.md) —— 功能拆解与里程碑
- [docs/interop.md](docs/interop.md) —— 互操作对拍记录
- [docs/references.md](docs/references.md) —— 参考实现与许可证
- [docs/proposal.md](docs/proposal.md) —— 项目申报书

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
