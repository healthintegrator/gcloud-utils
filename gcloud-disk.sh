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

# Name of the disk to create. When empty, a name will be generated from the name
# of the virtual machine, with an additional dash and 8 random ASCII characters
# or figures.
GCLOUD_DISK_NAME=${GCLOUD_DISK_NAME:-}

# Name of the zone where to create the disk and find the machine. Only zonal
# disks are supported at this point.
GCLOUD_DISK_ZONE=${GCLOUD_DISK_ZONE:-europe-north1-b}

# Name of the Google SDK Docker image to use. This can in theory be set to an
# empty string, in which case the script will use a local installation of
# gcloud. When no tag is specified, this is understood as the latest stable (not
# the latest).
GCLOUD_DISK_DOCKER=${GCLOUD_DISK_DOCKER:-google/cloud-sdk}

# Path to the service account key. This needs to be provided when running with
# Docker.
GCLOUD_DISK_KEY=${GCLOUD_DISK_KEY:-}

# Size of the disk, e.g. 20GB or 1TB. This is blindly passed to gcloud compute
# disk create.
GCLOUD_DISK_SIZE=${GCLOUD_DISK_SIZE:-10GB}

# Type of the disk, this is checked against the types of disks available within
# the zone. Examples, pd-standard, pd-balanced, pd-ssd
GCLOUD_DISK_TYPE=${GCLOUD_DISK_TYPE:-pd-standard}

# Project at Google. When empty, the default, the name of the project will be
# extracted from the JSON authentication key, if given.
GCLOUD_DISK_PROJECT=${GCLOUD_DISK_PROJECT:-}

# Name of the machine to attach the disk to. When empty, the default, the disk
# will not be attached to a machine.
GCLOUD_DISK_MACHINE=${GCLOUD_DISK_MACHINE:-}

# Name of the device to give to the disk when attaching the disk to a VM. When
# empty, the default, this will be the same as the name of the disk.
GCLOUD_DISK_DEV=${GCLOUD_DISK_DEV:-}



# Dynamic vars
cmdname=$(basename "$(readlink -f "$0")")
appname=${cmdname%.*}

# Print usage on stderr and exit
usage() {
  exitcode="$1"
  cat << USAGE >&2

Description:

  $cmdname creates a disk and attaches it to a VM at Google Compute Engine

Usage:
  $cmdname [-option arg --long-option(=)arg]

  where all dash-led options are as follows (long options can be followed by
  an equal sign):
    --silent            Be as silent as possible
    -k | --key          Path to service account key file (JSON)
    -n | --name         Disk name
    -d | --device       Device name reflected in /dev/disk/by-id/google-* tree
    -m | --machine      Name of machine to connect the disk to
    -s | --size         Size of the disk
    -t | --type         Type of the disk
    -z | --zone         Zone of the disk
    -p | --project      Google Cloud project to run against
    --docker            Fully qualified Docker image to use for gcloud

Details:
  By default, the device name will be the same as the name of the disk, which
  itself starts with the name of the machine, followed by a dash and 8 random
  characters, by default. In linux, the name of the device will be uniquely
  found as /dev/disk/by-id/google-XXXX, where XXXX is the name of the device.
  This file is a link to the attached block device, e.g. /dev/sdc or similar.

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
            GCLOUD_DISK_KEY=$2; shift 2;;
        --key=*)
            GCLOUD_DISK_KEY="${1#*=}"; shift 1;;

        -n | --name | --disk)
            GCLOUD_DISK_NAME=$2; shift 2;;
        --name=* | --disk=*)
            GCLOUD_DISK_NAME="${1#*=}"; shift 1;;

        -d | --device)
            GCLOUD_DISK_DEV=$2; shift 2;;
        --device=*)
            GCLOUD_DISK_DEV="${1#*=}"; shift 1;;

        -m | --machine)
            GCLOUD_DISK_MACHINE=$2; shift 2;;
        --machine=*)
            GCLOUD_DISK_MACHINE="${1#*=}"; shift 1;;

        -s | --size)
            GCLOUD_DISK_SIZE=$2; shift 2;;
        --size=*)
            GCLOUD_DISK_SIZE="${1#*=}"; shift 1;;

        -t | --type)
            GCLOUD_DISK_TYPE=$2; shift 2;;
        --type=*)
            GCLOUD_DISK_TYPE="${1#*=}"; shift 1;;

        -z | --zone)
            GCLOUD_DISK_ZONE=$2; shift 2;;
        --zone=*)
            GCLOUD_DISK_ZONE="${1#*=}"; shift 1;;

        -p | --project)
            GCLOUD_DISK_PROJECT=$2; shift 2;;
        --project=*)
            GCLOUD_DISK_PROJECT="${1#*=}"; shift 1;;

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
[ -z "$GCLOUD_DISK_SIZE" ] && gcloud_abort "You must provide a size for the disk"
[ -z "$GCLOUD_DISK_TYPE" ] && gcloud_abort "You must provide a type for the disk"
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    if [ -z "$GCLOUD_DISK_NAME" ]; then
        GCLOUD_DISK_NAME=${GCLOUD_DISK_MACHINE}-$(gcloud_random)
        log "Generated name of disk from machine name: $GCLOUD_DISK_NAME"
    fi
    if [ -z "$GCLOUD_DISK_DEV" ]; then
        log "Using $GCLOUD_DISK_NAME as the device name in host machine"
        GCLOUD_DISK_DEV=$GCLOUD_DISK_NAME
    fi
else
    warn "The disk will not be attached to a machine!"
fi
[ -z "$GCLOUD_DISK_NAME" ] && gcloud_abort "You must provide a (unique) disk name"
[ -z "$GCLOUD_DISK_ZONE" ] && gcloud_abort "You must provide a zone for the disk"
gcloud_init \
    --project "$GCLOUD_DISK_PROJECT" \
    --docker "$GCLOUD_DISK_DOCKER" \
    --key "$GCLOUD_DISK_KEY"
gcloud_login

# Verify input against what Google provides, e.g. zone, machine name, disk type,
# etc.
log "Verifying parameters..."
log "  Verifying zone"
if ! gcloud compute zones list | grep -q "$GCLOUD_DISK_ZONE"; then
    gcloud_abort "Zone $(red "$GCLOUD_DISK_ZONE") does not exist at GCloud"
fi
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    log "  Verifying machine"
    if ! gcloud compute instances describe --zone="$GCLOUD_DISK_ZONE" "$GCLOUD_DISK_MACHINE" >/dev/null 2>&1; then
        gcloud_abort "Machine $(red "$GCLOUD_DISK_MACHINE") does not seem to exist"
    fi
fi
log "  Verifying disk type"
if ! gcloud compute disk-types list --zones="$GCLOUD_DISK_ZONE" | grep -q "$GCLOUD_DISK_TYPE"; then
    gcloud_abort "Disk type $(red "$GCLOUD_DISK_TYPE") not available in $GCLOUD_DISK_ZONE"
fi

# Create Disk at Google, if it does not exist already.
if gcloud compute disks describe --zone="$GCLOUD_DISK_ZONE" "$GCLOUD_DISK_NAME" >/dev/null 2>&1; then
    warn "Disk $GCLOUD_DISK_NAME already exists in $GCLOUD_DISK_ZONE, will not change nor recreate"
else
    log "Creating disk $GCLOUD_DISK_NAME"
    if ! gcloud compute disks create "$GCLOUD_DISK_NAME" \
            --zone="$GCLOUD_DISK_ZONE" \
            --size="$GCLOUD_DISK_SIZE" \
            --type="$GCLOUD_DISK_TYPE" >/dev/null; then
        gcloud_abort "Could not create disk $(red "$GCLOUD_DISK_NAME")"
    fi
fi

# Attach disk, if relevant, i.e. if we have a machine to attach it to.
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    log "Attaching disk $GCLOUD_DISK_NAME to $GCLOUD_DISK_MACHINE"
    if ! gcloud compute instances attach-disk "$GCLOUD_DISK_MACHINE" \
            --zone="$GCLOUD_DISK_ZONE" \
            --disk="$GCLOUD_DISK_NAME" \
            --device-name="$GCLOUD_DISK_DEV" >/dev/null; then
        gcloud_abort "Could not attach disk $(red "$GCLOUD_DISK_NAME") to $GCLOUD_DISK_MACHINE!"
    fi

    # Verify that the disk was actually attached. This is probably superfluous.
    if gcloud compute instances describe "$GCLOUD_DISK_MACHINE" \
            --zone="$GCLOUD_DISK_ZONE" \
            --format="yaml(disks)"|grep "deviceName"|grep -q "$GCLOUD_DISK_NAME"; then
        log "Attached disk $(green "$GCLOUD_DISK_NAME") to $GCLOUD_DISK_MACHINE"
    else
        gcloud_abort "Disk not attached!"
    fi
fi

gcloud_exit
