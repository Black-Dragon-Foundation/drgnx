#!/usr/bin/env bash
# ipykernel at /opt/nb-kernel: the one install step of the notebook kernel, run at image build by the adapter image
# (debug-adapters-image.sh, Containerfile.debug, runtime.yml's debug-live job) and the GUI test image (Containerfile.gui,
# and so the Nidhogg line's GUI images, which are built on it). Nothing downloads after the build: the rows and the
# notebook scenes read the venv's python as DRGNX_NB_KERNEL_PYTHON (each image's ENV names it).
# The set is ipykernel-requirements.txt next to this script, hash-pinned (every file checked, the set is complete:
# --no-deps) and compiled for Python 3.15 (Fedora 45's python3): the venv is made from python3.15 itself, and the build
# stops if that interpreter is not there, so the install never meets another Python. The import check shows a gap in
# the set here, not in a test.  docs/develop/ci.md, "The debug adapters"
set -euo pipefail
command -v python3.15 > /dev/null || { echo "python3.15 is missing: ipykernel-requirements.txt was compiled for Python 3.15; recompile it for the image's python and change this pin" >&2; exit 1; }
python3.15 -m venv /opt/nb-kernel \
    && /opt/nb-kernel/bin/pip install --no-cache-dir --require-hashes --no-deps -r "$(dirname "$0")/ipykernel-requirements.txt" \
    && /opt/nb-kernel/bin/python3 -c 'import ipykernel, ipykernel_launcher; print("ipykernel", ipykernel.__version__)'
