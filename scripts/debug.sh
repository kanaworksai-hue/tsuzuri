#!/bin/bash
# Pokes a running Tsuzuri.app through distributed notifications (debug hooks).
# The hooks only exist in a build made with DEBUG_HOOKS=1 scripts/build-app.sh (never in
# releases), and are off unless that app was started with TSUZURI_DEBUG_HOOKS=1:
#
#   open --env TSUZURI_DEBUG_HOOKS=1 build/Tsuzuri.app
#
#   scripts/debug.sh dictate FILE.wav    # transcribe FILE and paste into the frontmost app
#   scripts/debug.sh overlay listening   # show the overlay (also: transcribing, hide, or any text)
#   scripts/debug.sh menu main           # open the menu for 4 s (or: languages, the Spoken Language submenu)
#   scripts/debug.sh permissions         # open the permissions window
set -euo pipefail
cmd=$1; arg=${2:-}
case $cmd in
  dictate) name=tsuzuri.debug.dictateFile; arg=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg") ;;
  overlay) name=tsuzuri.debug.overlay ;;
  menu) name=tsuzuri.debug.menu ;;
  permissions) name=tsuzuri.debug.permissions ;;
  *) echo "usage: $0 dictate FILE | overlay STATE | menu main|languages | permissions" >&2; exit 2 ;;
esac
/usr/bin/swift -e "import Foundation
DistributedNotificationCenter.default().postNotificationName(.init(\"$name\"), object: \"$arg\", userInfo: nil, deliverImmediately: true)"
