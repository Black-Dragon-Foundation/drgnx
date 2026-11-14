#!/usr/bin/env bash
# The live debug adapters, pinned: debugpy (pip --require-hashes), delve (Go's checksum database), js-debug (SHA-256),
# lldb-dap (Fedora's lldb) and CodeLLDB (SHA-256). Run as root on Fedora 45 by Containerfile.debug (the adapter image,
# drgnx-debug-adapters:f45) and by runtime.yml's `debug-live` job, so the two hold the same adapters. Nothing here
# downloads at test time.
set -euo pipefail

dnf -y install python3 python3-pip golang nodejs lldb clang gdb curl unzip strace \
    && dnf clean all

# debugpy (stdio adapter: python3 -m debugpy.adapter), from its wheel with the hash checked by pip.
printf 'debugpy==1.8.22 --hash=sha256:a9e9d3550e15ca479c59333e90845029190531f0cacfedab3b815a57bd913947\n' > /tmp/req.txt \
    && python3 -m pip install --no-cache-dir --require-hashes -r /tmp/req.txt && rm /tmp/req.txt

# delve (TCP adapter: dlv dap --listen=127.0.0.1:PORT): the module and every dependency are checked against the Go
# checksum database (its h1: hashes are SHA-256 of the module trees); delve v1.27.2 is
# h1:dhcjFjiVoQI53uwsG7EqYiMhdvFuywsBZx4KDOK+sYE=.
GOTOOLCHAIN=local GOFLAGS=-mod=mod GOPATH=/tmp/go GOBIN=/usr/local/bin \
    go install github.com/go-delve/delve/cmd/dlv@v1.27.2 \
    && rm -rf /tmp/go /root/.cache/go-build && dlv version

# js-debug (TCP adapter: node /opt/js-debug/src/dapDebugServer.js PORT 127.0.0.1), the js-debug-dap release tarball.
curl -sSfL -o /tmp/js-debug.tar.gz https://github.com/microsoft/vscode-js-debug/releases/download/v1.140.1/js-debug-dap-v1.140.1.tar.gz \
    && echo "c72fab31bcbfdce6ad1f42adfd28eff8d4681dd3b03b5e2e6f9e72e6f9927faf  /tmp/js-debug.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/js-debug.tar.gz -C /opt && rm /tmp/js-debug.tar.gz && test -f /opt/js-debug/src/dapDebugServer.js

# lldb-dap (stdio adapter) comes with Fedora's lldb package; check it is there.
command -v lldb-dap && lldb-dap --help > /dev/null

# CodeLLDB (TCP adapter: codelldb --port PORT), the linux-x64 .vsix (a zip) Install Adapter… fetches, at the same pin
# and SHA-256 as etc/debug-adapters.eld; it carries its own LLDB.
curl -sSfL -o /tmp/codelldb.vsix https://github.com/vadimcn/codelldb/releases/download/v1.12.3/codelldb-linux-x64.vsix \
    && echo "1cd7f386598022b51a5b93b9ffa23e812b23f519cfe1833384ec4bef4bfd1be1  /tmp/codelldb.vsix" | sha256sum -c - \
    && mkdir -p /opt/codelldb && unzip -q /tmp/codelldb.vsix 'extension/*' -d /opt/codelldb && rm /tmp/codelldb.vsix \
    && chmod +x /opt/codelldb/extension/adapter/codelldb && test -x /opt/codelldb/extension/adapter/codelldb
