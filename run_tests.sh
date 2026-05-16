#!/usr/bin/env bash
set -euo pipefail

cd grimmlink.koplugin
busted --coverage test/
