#!/usr/bin/env sh


#set -x

# All (good?) defaults
VERBOSE=1
MAINDIR=$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")
if [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

# Name of temporary Docker volume that will be created to store credentials
# between runs, if relevant.
VOLUME=

# Name of the disk to create. When empty, a name will be generated from the name
# of the virtual machine, with an additional dash and 8 random ASCII characters
# or figures.
GCLOUD_DISK_NAME=${GCLOUD_DISK_NAME:-}

# Name of the zone where to create the disk and find the machine. Only zonal
# disks are supported at this point.
GCLOUD_DISK_ZONE=${GCLOUD_DISK_ZONE:-europe-north1-b}

# Name of the Google SDK Docker image to use. This can in theory be set to an
# empty string, in which case the script will use a local installation of
# gcloud.
GCLOUD_DISK_DOCKER=${GCLOUD_DISK_DOCKER:-google/cloud-sdk:309.0.0-alpine}

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
        echo "[$(blue "$appname")] [$(yellow info)] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
    fi
}

warn() {
    echo "[$(blue "$appname")] [$(red WARN)] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
}

# Exit script, making sure to remove the Docker volume that temporarily carried
# credential information. We should really capture signals and bind on the
# termination signal to capture all cases. However, this script is meant to be
# run in controlled and automated contexts, so we should be fine.
clean_exit() {
    _code=${1:-0}
    if [ -n "$VOLUME" ]; then
        if docker volume ls | grep -q "$VOLUME"; then
            log "Removing Docker volume $VOLUME"
            docker volume rm "$VOLUME" >/dev/null
        fi
    fi

    exit "$_code"
}

# Abort program, making sure to cleanup.
abort() {
    warn "$1"
    clean_exit 1
}

# Generate a random string. Takes two params:
# $1 length of string, defaults to 8
# $2 set of characters allowed in string, defaults to lowercase or figures.
random() {
    _len=${1:-8}
    _charset=${2:-a-z0-9};  # Default is lower-case only to please Google
    tr -dc "${_charset}" < /dev/urandom | fold -w "${_len}" | head -n 1
}

# Generate good defaults from parameters and perform a first pass at verifying
# that we have enough parameters to actually start doing something.
[ -z "$GCLOUD_DISK_SIZE" ] && abort "You must provide a size for the disk"
[ -z "$GCLOUD_DISK_TYPE" ] && abort "You must provide a type for the disk"
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    if [ -z "$GCLOUD_DISK_NAME" ]; then
        GCLOUD_DISK_NAME=${GCLOUD_DISK_MACHINE}-$(random)
        log "Generated name of disk from machine name: $GCLOUD_DISK_NAME"
    fi
    if [ -z "$GCLOUD_DISK_DEV" ]; then
        log "Using $GCLOUD_DISK_NAME as the device name in host machine"
        GCLOUD_DISK_DEV=$GCLOUD_DISK_NAME
    fi
else
    warn "The disk will not be attached to a machine!"
fi
[ -z "$GCLOUD_DISK_NAME" ] && abort "You must provide a (unique) disk name"
[ -z "$GCLOUD_DISK_ZONE" ] && abort "You must provide a zone for the disk"
if [ -n "$GCLOUD_DISK_DOCKER" ] && [ -z "$GCLOUD_DISK_KEY" ]; then
    abort "You must provide a service account key for authentication"
fi
if [ -z "$GCLOUD_DISK_PROJECT" ] && [ -n "$GCLOUD_DISK_KEY" ]; then
    GCLOUD_DISK_PROJECT=$(grep 'project_id"' "$GCLOUD_DISK_KEY" | sed -E 's/\s*"project_id"\s*:\s*"([^"]*)".*/\1/')
    log "Extracted project ID $(blue "$GCLOUD_DISK_PROJECT") from key file"
fi
[ -z "$GCLOUD_DISK_PROJECT" ] && abort "You must provide a GCloud project identifier"

# Create a Docker volume in which we will be storing credentials for the
# lifetime of the script. This volume is automatically cleaned up on exit.
if [ -n "$GCLOUD_DISK_DOCKER" ]; then
    if ! docker --version 2>&1 >/dev/null; then
        abort "You must have an installation of Docker accessible to you"
    fi
    log "Pulling image $(yellow "$GCLOUD_DISK_DOCKER") for gcloud operations"
    docker image pull "$GCLOUD_DISK_DOCKER" >/dev/null
    VOLUME="${appname}"-$(random)
    log "Creating Docker volume $(yellow "$VOLUME") to temporarily store credentials"
    docker volume create "$VOLUME" >/dev/null
fi

# This is an internal relay alias against the gcloud command. This script has
# only been tested with a Docker image and running a number of containers, but
# it should be able to run locally also.
gcloud() {
    if [ -z "$VOLUME" ]; then
        gcloud --project "$GCLOUD_DISK_PROJECT" $@
    else
        # When running through Docker, we arrange for two volume mounts: The
        # first volume is pointed to where gcloud stores its credentials and
        # configuration so that consecutive calls will keep authorisation data
        # as the phases of the script progress. The second mount recreates the
        # same directory structure as where the key file is located. This is
        # only used at authorisation time, so that the call will look the same
        # with or without docker.
        docker run --rm \
            -v "${VOLUME}:/root/.config/gcloud" \
            "$GCLOUD_DISK_DOCKER" \
            gcloud --project "$GCLOUD_DISK_PROJECT" $@
    fi
}

# Copy a file into a volume, implicitely using the same Docker image as the one
# used within the remaining of this script to avoid extra downloads. The volume
# is mounted on a directory with random letters to avoid name collisions.
# Arguments are:
# $1: Path to the file (mandatory)
# $2: Name of the destination volume (mandatory)
# $3: Name of the destination file in the volume, defaults to basename of $1
volume_cp() {
    _dst=${3:-$(basename "$1")}
    _dirname=${appname}_$(random)
    cat "$1" |
        docker run -i --rm \
            -v "${2}:/${_dirname}" \
            "$GCLOUD_DISK_DOCKER" \
            tee "/${_dirname}/${_dst}" >/dev/null
}

# Any use of the gcloud command requires authentication, so we start by doing
# this as soon as possible.
if [ -n "$GCLOUD_DISK_KEY" ]; then
    log "Logging in at GCloud with $(red "$GCLOUD_DISK_KEY")"
    # If running without Docker, we have an empty VOLUME. In that case, we
    # simply authenticate locally. When running Docker, this is more
    # cumbersome... For unknown reasons, it is NOT possible to mount the file
    # into a container to be able to read it from the "gcloud auth" call. While
    # this works at the command line, it does NOT work when automated from
    # machinery. Instead, we copy the file into the temporary volume and
    # authenticate from the copy.
    if [ -z "$VOLUME" ]; then
        if ! gcloud auth activate-service-account \
                --key-file "$GCLOUD_DISK_KEY"; then
            abort "Could not login at GCloud"
        fi
    else
        # Find name of key file, so we copy into the docker container and keep naming.
        _keyfile=$(basename "$GCLOUD_DISK_KEY")

        # Copy the content of the locally available and readable key file into
        # the volume that is designated to carry gcloud-specific configuration
        # data. We encapsulate by prefixing the name of the application to avoid
        # name collisions.
        volume_cp "$GCLOUD_DISK_KEY" "${VOLUME}" "${appname}_${_keyfile}"
        # Now login using the copy of the file within the volume.
        if ! docker run --rm \
                -v "${VOLUME}:/root/.config/gcloud" \
                "$GCLOUD_DISK_DOCKER" \
                gcloud auth activate-service-account \
                    --key-file "/root/.config/gcloud/${appname}_${_keyfile}" >/dev/null; then
            abort "Could not login at GCloud"
        fi
    fi
fi

# Verify input against what Google provides, e.g. zone, machine name, disk type,
# etc.
log "Verifying parameters..."
log "  Verifying zone"
if ! gcloud compute zones list | grep -q "$GCLOUD_DISK_ZONE"; then
    abort "Zone $(red "$GCLOUD_DISK_ZONE") does not exist at GCloud"
fi
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    log "  Verifying machine"
    if ! gcloud compute instances describe --zone="$GCLOUD_DISK_ZONE" "$GCLOUD_DISK_MACHINE" 2>&1 >/dev/null; then
        abort "Machine $(red "$GCLOUD_DISK_MACHINE") does not seem to exist"
    fi
fi
log "  Verifying disk type"
if ! gcloud compute disk-types list --zones="$GCLOUD_DISK_ZONE" | grep -q "$GCLOUD_DISK_TYPE"; then
    abort "Disk type $(red "$GCLOUD_DISK_TYPE") not available in $GCLOUD_DISK_ZONE"
fi

# Create Disk at Google, if it does not exist already.
if gcloud compute disks describe --zone="$GCLOUD_DISK_ZONE" "$GCLOUD_DISK_NAME" 2>&1 >/dev/null; then
    warn "Disk $GCLOUD_DISK_NAME already exists in $GCLOUD_DISK_ZONE, will not change nor recreate"
else
    log "Creating disk $GCLOUD_DISK_NAME"
    if ! gcloud compute disks create "$GCLOUD_DISK_NAME" \
            --zone="$GCLOUD_DISK_ZONE" \
            --size="$GCLOUD_DISK_SIZE" \
            --type="$GCLOUD_DISK_TYPE" >/dev/null; then
        abort "Could not create disk $(red "$GCLOUD_DISK_NAME")"
    fi
fi

# Attach disk, if relevant, i.e. if we have a machine to attach it to.
if [ -n "$GCLOUD_DISK_MACHINE" ]; then
    log "Attaching disk $GCLOUD_DISK_NAME to $GCLOUD_DISK_MACHINE"
    if ! gcloud compute instances attach-disk "$GCLOUD_DISK_MACHINE" \
            --zone="$GCLOUD_DISK_ZONE" \
            --disk="$GCLOUD_DISK_NAME" \
            --device-name="$GCLOUD_DISK_DEV" >/dev/null; then
        abort "Could not attach disk $(red "$GCLOUD_DISK_NAME") to $GCLOUD_DISK_MACHINE!"
    fi

    # Verify that the disk was actually attached. This is probably superfluous.
    if gcloud compute instances describe "$GCLOUD_DISK_MACHINE" \
            --zone="$GCLOUD_DISK_ZONE" \
            --format="yaml(disks)"|grep "deviceName"|grep -q "$GCLOUD_DISK_NAME"; then
        log "Attached disk $(green "$GCLOUD_DISK_NAME") to $GCLOUD_DISK_MACHINE"
    else
        abort "Disk not attached!"
    fi
fi

clean_exit
