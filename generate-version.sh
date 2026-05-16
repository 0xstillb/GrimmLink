#!/bin/bash
set -e

VERSION_FILE="grimmlink.koplugin/plugin_version.lua"
META_FILE="grimmlink.koplugin/_meta.lua"

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

if git describe --tags --exact-match HEAD 2>/dev/null; then
    VERSION=$(git describe --tags --exact-match HEAD)
    VERSION_TYPE="release"
elif git describe --tags 2>/dev/null; then
    VERSION=$(git describe --tags --always)
    VERSION_TYPE="development"
elif [ "$GIT_COMMIT" != "unknown" ]; then
    VERSION="0.0.0-dev+$GIT_COMMIT"
    VERSION_TYPE="development"
else
    VERSION="0.0.0-dev"
    VERSION_TYPE="development"
fi

BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$VERSION_FILE" <<EOF
return {
    version = "$VERSION",
    version_type = "$VERSION_TYPE",
    git_commit = "$GIT_COMMIT",
    build_date = "$BUILD_DATE",
}
EOF

cat > "$META_FILE" <<EOF
local _ = require("gettext")
return {
    name = "grimmlink",
    fullname = _("GrimmLink"),
    description = _("KOReader Companion for Grimmory"),
    version = "$VERSION",
}
EOF

echo "Version: $VERSION ($VERSION_TYPE) commit=$GIT_COMMIT"
