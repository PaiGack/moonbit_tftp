# 参考实现与许可证

本项目为独立实现，规格以 RFC 为准；下列实现仅用于理解行为语义与对拍验证。

## 规范

| 文档 | 内容 |
| --- | --- |
| RFC 1350 | TFTP 基础协议 |
| RFC 2347 | 选项扩展框架 |
| RFC 2348 | `blksize` 选项 |
| RFC 2349 | `timeout` / `tsize` 选项 |

## 参考实现

| 项目 | 语言 | 许可证 | 用途 |
| --- | --- | --- | --- |
| [tftp-hpa](https://git.kernel.org/pub/scm/network/tftp/tftp-hpa.git) | C | BSD-3-Clause | 语义对齐、互操作测试对手 |
| [atftp](https://sourceforge.net/projects/atftp/) | C | GPL-2.0 | 行为参考（**不参考其代码**） |
| [tftpy](https://github.com/msoulier/tftpy) | Python | MIT | 状态机行为、测试向量 |
| [curl](https://curl.se/) | C | curl（MIT 风格） | 互操作对拍 |

## 许可兼容说明

- 本项目采用 **Apache-2.0**。
- BSD-3-Clause / MIT / curl 许可证与 Apache-2.0 兼容，可直接作为
  互操作测试的对手程序，也可在注明来源的前提下参考其接口行为。
- **GPL-2.0 的 atftp 仅用作外部行为对照**，本项目不复制、不改编其源代码，
  仅在文档中记录其表现出的协议行为（这些行为本身由 RFC 规定）。
- 所有测试中用到的第三方程序均为「作为外部进程调用」，不构成本仓库的
  衍生作品。
