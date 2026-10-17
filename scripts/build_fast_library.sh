#!/bin/bash
# Backward compatibility wrapper for build_release_zip.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/build_release_zip.sh" "$@"
