#!/usr/bin/env sh

ROOT_DIR=$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )
LIBDIR=
[ -d "${ROOT_DIR}/lib" ] && LIBDIR="${ROOT_DIR}/lib"
[ -z "$LIBDIR" ] && [ -d "${ROOT_DIR}/../lib" ] && LIBDIR="${ROOT_DIR}/../lib"
[ -z "$LIBDIR" ] && echo "Cannot find lib dir!" >&2 && exit 1

set -ef

#set -x

# All (good?) defaults
VERBOSE=1
if [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

# Path to the service account key. This needs to be provided when running with
# Docker.
GCLOUD_TAGS_KEY=${GCLOUD_TAGS_KEY:-}

# Project at Google. When empty, the default, the name of the project will be
# extracted from the JSON authentication key, if given.
GCLOUD_TAGS_PROJECT=${GCLOUD_TAGS_PROJECT:-}

# Name of the zone where to find the machine.
GCLOUD_TAGS_ZONE=${GCLOUD_TAGS_ZONE:-europe-north1-b}

# Name of the machine to attach the tags to.
GCLOUD_TAGS_MACHINE=${GCLOUD_TAGS_MACHINE:-}

# Dynamic vars
cmdname=$(basename "$(readlink -f "$0")")
appname=${cmdname%.*}

# Print usage on stderr and exit
usage() {
  exitcode="$1"
  cat << USAGE >&2

Description:

  $cmdname attaches network tags to a VM at Google Compute Engine

Usage:
  $cmdname [-option arg --long-option(=)arg] -- tags...

  where all dash-led options are as follows (long options can be followed by
  an equal sign):
    --silent            Be as silent as possible
    -p | --project      Google Cloud project to run against
    -k | --key          Path to service account key file (JSON)
    -m | --machine      Name of machine to connect the disk to
    -z | --zone         Zone of the machine

USAGE
  exit "$exitcode"
}

# Source in all relevant modules. This is where most of the "stuff" will occur.
for module in log gcloud; do
  module_path="${LIBDIR}/${module}.sh"
  if [ -f "$module_path" ]; then
    # shellcheck disable=SC1090
    . "$module_path"
  else
    echo "Cannot find module $module at $module_path !" >& 2
    exit 1
  fi
done

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -k | --key)
            GCLOUD_TAGS_KEY=$2; shift 2;;
        --key=*)
            GCLOUD_TAGS_KEY="${1#*=}"; shift 1;;

        -m | --machine)
            GCLOUD_TAGS_MACHINE=$2; shift 2;;
        --machine=*)
            GCLOUD_TAGS_MACHINE="${1#*=}"; shift 1;;

        -p | --project)
            GCLOUD_TAGS_PROJECT=$2; shift 2;;
        --project=*)
            GCLOUD_TAGS_PROJECT="${1#*=}"; shift 1;;

        -z | --zone)
            GCLOUD_TAGS_ZONE=$2; shift 2;;
        --zone=*)
            GCLOUD_TAGS_ZONE="${1#*=}"; shift 1;;

        --silent)
            VERBOSE=0; shift;;

        -h | --help)
            usage 0;;
        --)
            shift; break;;
        -*)
            echo "Unknown option: $1 !" >&2 ; usage 1;;
        *)
            break;;
    esac
done

# Generate good defaults from parameters and perform a first pass at verifying
# that we have enough parameters to actually start doing something.
[ -z "$GCLOUD_TAGS_MACHINE" ] && gcloud_abort "You must provide a machine to attach tags to"
[ -z "$GCLOUD_TAGS_ZONE" ] && gcloud_abort "You must provide a zone"
gcloud_init \
    --project "$GCLOUD_TAGS_PROJECT" \
    --key "$GCLOUD_TAGS_KEY"
gcloud_login

# Verify input against what Google provides
log "Verifying machine"
if ! gcloud compute instances describe --zone="$GCLOUD_TAGS_ZONE" "$GCLOUD_TAGS_MACHINE" 2>&1 >/dev/null; then
    gcloud_abort "Machine $(red "$GCLOUD_TAGS_MACHINE") does not seem to exist"
fi

# Get list of known tags for instance and add the missing ones.
tags=$( gcloud compute instances list \
                --format='table(name,tags.items.list())' |
        grep -E "^${GCLOUD_TAGS_MACHINE}[[:space:]]+" |
        awk '{print $2;}' |
        tr ',' ' ' )
for tag in "$@"; do
    if printf %s\\n "$tags" | grep -q "$tag"; then
        warn "Tag $tag already present at $GCLOUD_TAGS_MACHINE"
    else
        log "Adding network tag $(green "$tag") to instance $GCLOUD_TAGS_MACHINE"
        gcloud compute instances add-tags "$GCLOUD_TAGS_MACHINE" \
            --zone "$GCLOUD_TAGS_ZONE" \
            --tags "$tag"
    fi
done
gcloud_exit
