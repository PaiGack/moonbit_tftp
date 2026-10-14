# PaiGack/tftp

TFTP（Trivial File Transfer Protocol，简单文件传输协议）的纯 MoonBit 实现，
覆盖 RFC 1350 基础协议与 RFC 2347/2348/2349 的选项扩展。

- 上游仓库：<https://github.com/PaiGack/moonbit_tftp>
- 包名：`PaiGack/tftp`
- 许可证：Apache-2.0

## 目标

做成一个「协议库 + 客户端 + 服务端 + 命令行」的完整实现，各层共享报文编解码：

- **报文层**：RRQ / WRQ / DATA / ACK / ERROR / OACK 的编解码（`encode` / `decode`），
  通道模式（netascii / octet），畸形报文以 `DecodeError` 返回
  （`Truncated` / `UnknownOpcode` / `MissingTerminator` / `FieldTooLong` /
  `Unsupported`，各自指名道姓），block 号 u16 回绕。
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

首次在干净环境（新容器 / 新机器）里跑之前，先同步一次 MoonBit registry 索引：

```bash
moon update         # 首次必跑：拉取 registry 索引，否则依赖解析失败
```

`moon update` 把 MoonBit registry 的索引克隆到本地（`~/.moon/registry`），
`moon` 靠它才能把 `moon.mod` 里的模块名解析成具体版本。这一步只在首次
或用久了之后需要，日常改代码不必重复执行。

> 跳过它的典型报错是 `Failed to calculate build plan` +
> `module was not found in the registry`（例如 `mizchi/x`、`moonbitlang/async`、
> `moonbitlang/regexp`），同时伴随提示 `you may need to run 'moon update'`。
> CI（`scripts/ci.sh`）与 Copilot 环境（`.github/workflows/copilot-setup-steps.yml`）
> 都已把 `moon update` 作为第一步。

索引就位后，日常循环是：

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

无法解析的请求同样回 ERROR 4（RFC 1350 §5 里 4 是「此刻不接受这个请求」的
唯一通路），不会静默丢弃：静默丢弃只会让对端一直重传到预算耗尽。

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
| `--timeout N` | 单包超时（秒，1~255） | `5` |
| `--retries N` | 放弃前的重传次数 | `6` |
| `--netascii` | 使用 netascii 模式（默认 octet） | 关闭 |

退出码：`0` 成功；`1` 传输失败（对端报错 / 超时 / 本地读写失败）；
`2` 命令行用法错误。

超出范围的取值按用法错误拒绝（退出码 `2`），不发给对端：服务端有权忽略
它不认的选项（RFC 2347 §2），而客户端如果照原值继续跑，两边对「一个块有
多大」的理解会不一致，最后是干等到超时，而不是一条能看懂的报错。

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

文本文件用 `--netascii` 时同理，只是行尾在线上变成 CRLF、两端各自转回来，
所以比对对象是本地那份原文，而不是服务端磁盘上的字节：

```bash
# 终端 B
printf 'line one\nline two\n' > ./config.txt
moon run cmd/main -- put 127.0.0.1:6969 ./config.txt --netascii
moon run cmd/main -- get 127.0.0.1:6969 config.txt ./got.txt --netascii
cmp ./config.txt ./got.txt && echo "byte-for-byte identical"
```

只跑单向会漏掉服务端那半边的转换：客户端编码 + 服务端透传在「源文件本来就是
CRLF」时会假装全绿，换成 LF 源文件才暴露。完整往返与假阳性的来龙去脉见
[docs/interop.md](docs/interop.md)。

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

TFTP 基于 UDP，需要宿主提供真实网络栈，`wasm` / `wasm-gc` 后端无法提供，
故声明为 `native`。仓库在 `moon.mod` 里写明了这一点：

```
// TFTP 需要真实网络栈（UDP），wasm/wasm-gc 后端无法提供，故声明为 native。

preferred_target = "native"
```

换句话说：

- `native` 是唯一支持的目标，`scripts/ci.sh` 的 check / test / build 全跑在它上面。
- `js` / `wasm` / `wasm-gc` 不在支持范围内，仓库不承诺它们能编译、能跑。
- 协议层（报文编解码、选项协商、netascii）与状态机是纯函数，不碰 socket，
  理论上可在任意后端离线使用；但一碰到 `moonbitlang/async` 的 `socket` / `fs`
  （`server_fs.mbt`、`transport_socket.mbt`）就回到 native 这条路上。

## 文档

- [docs/protocol.md](docs/protocol.md) —— TFTP 协议速览
- [docs/architecture.md](docs/architecture.md) —— 包结构与设计
- [docs/roadmap.md](docs/roadmap.md) —— 功能拆解与里程碑
- [docs/interop.md](docs/interop.md) —— 互操作对拍记录
- [docs/references.md](docs/references.md) —— 参考实现与许可证
- [docs/proposal.md](docs/proposal.md) —— 项目申报书

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
