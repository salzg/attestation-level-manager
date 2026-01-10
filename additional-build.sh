#!/bin/bash
# Commands executed inside the base-image chroot during build-base, after the standard apt install + snpguest installation.
set -euo pipefail

# Example: install extra packages
# apt-get update
# apt-get install -y --no-install-recommends jq tmux

# Example: drop a marker
# echo "built-with-build-extra" >/etc/alman-build-extra
