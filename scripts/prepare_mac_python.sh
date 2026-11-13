#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
if ! brew list --versions python@3.13 >/dev/null 2>&1; then
    brew install python@3.13
fi
ci_python="$(brew --prefix python@3.13)/bin/python3.13"
ci_environment="$RUNNER_TOOL_CACHE/openminis-python-3.13"
if [ ! -x "$ci_environment/bin/python3" ]; then
    "$ci_python" -m venv "$ci_environment"
fi
"$ci_environment/bin/python3" --version
PIP_CONFIG_FILE=/dev/null "$ci_environment/bin/python3" -m pip install \
    --disable-pip-version-check --no-input --index-url https://pypi.org/simple \
    -r scripts/requirements-ios-ci.txt
echo "$ci_environment/bin" >> "$GITHUB_PATH"
echo "VIRTUAL_ENV=$ci_environment" >> "$GITHUB_ENV"
