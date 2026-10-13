# 互操作对拍记录

本页记录 `moon-tftp` 与外部 TFTP 实现的实测结果。对拍的意义在于：仓库内的
测试替身只回答「我们希望对端怎么答」，而真实实现对协议的理解是独立写出来的，
它能暴露测试替身容忍、而 RFC 不允许的偏差。

## 对拍对象

| 对象 | 版本 | 角色 |
| --- | --- | --- |
| [curl](https://curl.se/) | 系统自带（`--version` 显示 `tftp` 协议） | 客户端，对拍本项目的 `serve` |
| 本项目 CLI | 本仓库 `cmd/main` | 服务端 / 客户端 |

curl 的 TFTP 实现严格遵循 RFC 1350/2347，是很好的「外部裁判」。

## 方法

1. 启动本项目的服务端，发布一个测试目录：
   `moon-tftp serve --root /tmp/tftproot --port 6969 --allow-overwrite`
2. 用 curl 读写该服务端，用 `cmp` 对比下载内容与源文件。
3. 反向：用本项目的 `get` / `put` 读写真实端点，验证客户端侧。

## 结果

### 对拍一：curl 作为客户端，本项目的服务端

| 用例 | 命令 | 结果 |
| --- | --- | --- |
| 单块下载 | `curl tftp://127.0.0.1:6969/hello.txt` | ✅ 内容一致 |
| 多块下载 | `curl tftp://127.0.0.1:6969/blob.bin`（4096 B） | ✅ `cmp` 逐字节一致 |
| 协商 blksize=1024 | `curl --tftp-blksize 1024 .../blob.bin` | ✅ 逐字节一致 |
| 协商 blksize=512 | `curl --tftp-blksize 512 .../hello.txt` | ✅ 内容一致 |
| netascii 模式 | `curl "tftp://.../hello.txt;mode=netascii"` | ✅ 内容一致 |
| 上传（WRQ） | `curl -T /tmp/up.txt tftp://127.0.0.1:6969/up.txt` | ✅ 服务端落盘 |

curl 通过 OACK 协商路径与本项目的服务端完成握手，并在多块文件上完成
停等传输，说明服务端的 OACK 生成、首包时序、短块结束判定与真实客户端兼容。

### 对拍二：本项目的客户端

| 用例 | 结果 |
| --- | --- |
| `get` 单块 / 多块文件（真实服务端，非测试替身） | ✅ 逐字节一致 |
| `put` 5000 / 100000 / 4096 字节文件 | ✅ 落盘逐字节一致 |
| `get --blksize 1024` | ✅ 逐字节一致 |
| 对端文件不存在 | ✅ 报 ERROR 1 |

### 对拍暴露并修复的两个问题

这两处此前都被内存测试替身「宽容掉」，只有真实对端才触发：

1. **客户端在 RRQ 的 OACK 后未回 ACK 0**。RFC 2347 要求客户端用 ACK 0
   确认 OACK，之后服务端才发 DATA 1。仓库内的测试替身收到 OACK 就直接发
   DATA 1，掩盖了这一点；面对本项目自己的 `serve_read` 或 curl 时，客户端会
   一直等不到 DATA。修复：`get` 在 OACK 握手完成后先发 ACK 0。
   回归测试：`client_test.mbt` 的 “get acknowledges an OACK before the data arrives”。

2. **服务端写会话未发送最后一块的 ACK**。对短块（文件结尾）服务端提前
   `return`，把尾 ACK 留在了循环顶部的发送点之外，客户端于是重传最后一块、
   直到超时。修复：返回前显式发送该 ACK。
   回归测试：`client_test.mbt` 的 “the last block of a write is acknowledged”。

## 复现

本机一条命令即可复现双向对拍：

```bash
moon run cmd/main -- serve --root /tmp/tftproot --port 6969 --allow-overwrite &
curl -s tftp://127.0.0.1:6969/hello.txt -o /tmp/out.txt
cmp /tmp/tftproot/hello.txt /tmp/out.txt && echo identical
```

## 未覆盖

- 尚未与 tftp-hpa / atftp 对拍：环境中没有这两个程序。它们的语义已在
  `docs/references.md` 中登记，作为后续补充对拍的目标。
- 丢包 / 乱序 / 重复包在真实网络下的表现：目前由内存传输上的注入用例覆盖。
