# 架构设计

## 包结构

```
PaiGack/tftp
├── moon.mod                 模块元数据（名称 / 版本 / 仓库 / 许可证）
├── moon.pkg                 根包：协议报文层 + 客户端
├── tftp.mbt                 公开 API（报文编解码、opcode / 模式 / 错误码枚举）
├── options.mbt              公开 API（RFC 2347 选项协商、OACK、拒绝路径）
├── transport.mbt            公开 API（UDP 收发抽象 Transport、Datagram、Recv）
├── transport_memory.mbt     公开 API（内存实现，离线测试用）
├── transport_socket.mbt     公开 API（客户端真实 UDP 套接字实现）
├── transport_socket_wbtest.mbt  白盒测试（真实 UDP 套接字实现）
├── client.mbt               公开 API（get / put 停等状态机）
├── server.mbt               公开 API（请求处理 / 会话状态机 / TID 分发 / 路径约束）
├── server_fs.mbt            公开 API（真实文件系统后端 + socket 会话传输，
                               并让它实现 Transport 以便 CLI 驱动会话）
├── server_memory.mbt        公开 API（内存文件系统，离线测试用）
├── block.mbt                公开 API（block 号 u16 回绕比较）
├── netascii.mbt             公开 API（netascii 转换，含跨块行尾）
├── tftp_test.mbt            黑盒测试（只看公开 API）
├── options_test.mbt         黑盒测试（选项协商矩阵）
├── client_test.mbt          黑盒测试（状态机 + 内存传输上的完整会话）
├── server_test.mbt          黑盒测试（路径约束 / 错误码矩阵 / 会话 / 并发）
├── block_test.mbt           黑盒测试（回绕比较）
├── netascii_test.mbt        黑盒测试（转换与块边界）
├── tftp_wbtest.mbt          白盒测试（可访问内部实现）
├── server_fs_wbtest.mbt     白盒测试（真实文件系统 + socket 会话）
├── cmd/main/                CLI 可执行入口
│   ├── main.mbt            get / put / serve 子命令实现
│   └── main_wbtest.mbt     白盒测试（CLI 子命令 / 参数解析）
└── docs/                    设计文档
```

MoonBit 以目录为包，`moon.pkg` 声明该包依赖；测试按 `_test.mbt`（黑盒）
与 `_wbtest.mbt`（白盒）分文件。

## 分层

```
        ┌─────────────┐
        │   cmd/main  │  CLI: get / put / serve
        └──────┬──────┘
     ┌─────────┴─────────┐
┌────▼────┐        ┌─────▼─────┐
│ client  │        │  server   │   server 只依赖 FileSystem + Transport
└────┬────┘        └─────┬─────┘
     └────────┬─────────┘
        ┌─────▼─────┐
        │  protocol │  报文编解码 / 选项协商 / 模式转换
        └─────┬─────┘
        ┌─────▼─────┐
        │  options  │  RFC 2347：解析 / 校验 / OACK / ERROR 8
        └─────┬─────┘
        ┌─────▼─────┐
        │ transport │  UDP socket 收发（可替换，便于测试）
        └───────────┘
```

服务端与客户端共享同一套协议层、选项协商与传输抽象，差别只在状态机的
方向：客户端发请求，服务端收请求。服务端的文件系统（`FileSystem`）也是
一个最小接口，真实实现是 `server_fs.mbt`，测试用 `server_memory.mbt` 的
内存实现——磁盘满是真实机器上最难复现的分支，在内存实现里只是一个字段。

设计原则：

1. **协议层不碰 socket。** 报文编解码、选项协商、netascii 转换都是纯函数，
   可在任意后端 `moon test`，不依赖网络。选项协商分两步走：`parse_options`
   负责「客户端要什么」，`resolve_options` 把服务端能给的答案合进去，
   服务端只提供 `RequestedOption -> Result[String?, NegotiationError]` 回调。
2. **传输层可替换。** 客户端 / 服务端只依赖一个最小的 UDP 收发接口，
   测试时注入内存实现即可离线跑完整会话。
3. **会话状态机显式化。** 客户端与服务端各有一个状态机，输入是
   「收到报文 / 超时」，输出是「要发的报文 / 结果」，便于单测覆盖。

## 依赖

UDP 收发基于社区 socket 抽象 `mizchi/x/socket`（底层为 `moonbitlang/async`），
不自行编写底层绑定。客户端与状态机不直接依赖它：`transport.mbt` 只定义一个
最小的 `Transport` trait，socket 实现是它的一个后端，测试注入内存实现
（`transport_memory.mbt`）。这也让「协议层 / 状态机不碰 socket」这条原则
可以被 grep 直接验证。

## 测试策略

| 层次 | 手段 |
| --- | --- |
| 报文编解码 | 手工构造字节序列做往返（round-trip）断言 |
| 选项协商 | 覆盖接受 / 拒绝 / 缺省回退 / 非法取值 / 未知选项名 |
| netascii | 边界字符（`\n`、`\r`、行尾跨块） |
| 状态机 | 注入时序事件，断言状态转移与输出报文 |
| 端到端 | 内存传输后端上跑 client ↔ server 全流程 |
| 客户端 | 内存传输上跑完整 get / put，覆盖重传、去重、回绕、netascii 跨块 |
| 服务端 | 路径穿越用例（`..`、绝对路径、编码绕过）、错误码逐个触发、
内存文件系统上跑完整读 / 写全流程 |
| 并发 | 多会话并行跑，断言各自的文件互不串扰 |
| TID | `Dispatcher` 对请求 / 错位报文 / 畸形报文的三种判定 |
| 会话上限 | 达到 `max_sessions` 后新请求回 ERROR 4，已有会话的 TID 不受影响 |
