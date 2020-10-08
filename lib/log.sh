#!/usr/bin/env sh

VERBOSE=${VERBOSE:-0}
if [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

# Colourisation support for logging and output.
_colour() {
  if [ "$INTERACTIVE" = "1" ]; then
    printf '\033[1;31;'${1}'m%b\033[0m' "$2"
  else
    printf -- "%b" "$2"
  fi
}
green() { _colour "32" "$1"; }
red() { _colour "40" "$1"; }
yellow() { _colour "33" "$1"; }
blue() { _colour "34" "$1"; }

# Conditional logging
log() {
  if [ "$VERBOSE" = "1" ]; then
    echo "[$(blue "${2:-$appname}")] [$(yellow info)] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
  fi
}

warn() {
  echo "[$(blue "${2:-$appname}")] [$(red WARN)] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
}
