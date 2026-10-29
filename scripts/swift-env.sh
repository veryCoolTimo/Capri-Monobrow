#!/usr/bin/env bash
# Select a full Xcode for XCTest without changing the user's global xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
