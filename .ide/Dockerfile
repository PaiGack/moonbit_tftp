# .ide/Dockerfile

FROM cnbcool/default-dev-env:latest

# `openssl` is used by the FTPS test path: `scripts/ftps/gen-cert.sh` mints the
# throwaway CA + leaf on every run, and `scripts/ftps/probe-ftps.sh` drives the
# `AUTH TLS` readiness handshake with `s_client`. `python3` stays because
# `scripts/probe-ftp.py` probes the plaintext container.
RUN apt-get update && apt-get install -y \
      gcc libc6-dev libssl-dev strace python3 openssl

RUN curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash \
     && code-server --install-extension moonbit.moonbit-lang

RUN curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash

RUN curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash

ENV workspace="/workspace"

RUN code-server --install-extension tamasfe.even-better-toml \
     && code-server --install-extension usernamehw.errorlens \
     && code-server --install-extension chanhx.crabviz \
     && code-server --install-extension golang.Go \
     && code-server --install-extension Anthropic.claude-code
