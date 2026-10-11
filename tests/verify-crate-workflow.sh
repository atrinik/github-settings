#!/usr/bin/env bash

set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "${root}/tests/verify_crate_workflow.py"
