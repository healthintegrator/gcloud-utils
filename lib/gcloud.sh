#!/usr/bin/env sh

# Name of the Google SDK Docker image to use. This can in theory be set to an
# empty string, in which case the script will use a local installation of
# gcloud.
GCLOUD_DOCKER=${GCLOUD_DOCKER:-google/cloud-sdk:309.0.0-alpine}

# Path to the service account key. This needs to be provided when running with
# Docker.
GCLOUD_KEY=${GCLOUD_KEY:-}

# Project at Google. When empty, the default, the name of the project will be
# extracted from the JSON authentication key, if given.
GCLOUD_PROJECT=${GCLOUD_PROJECT:-}

# Name of temporary Docker volume that will be created to store credentials
# between runs, if relevant.
VOLUME=

gcloud_options() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d | --docker)
        GCLOUD_DOCKER="$2"; shift 2;;
      --docker=*)
        GCLOUD_DOCKER="${1#*=}"; shift 1;;

      -k | --key)
        GCLOUD_KEY="$2"; shift 2;;
      --key=*)
        GCLOUD_KEY="${1#*=}"; shift 1;;

      -p | --project)
        GCLOUD_PROJECT="$2"; shift 2;;
      --project=*)
        GCLOUD_PROJECT="${1#*=}"; shift 1;;

      -*)
        warn "$1 is not a known option"; shift 2;;

      *)
        break;;
    esac
  done
}

# Exit script, making sure to remove the Docker volume that temporarily carried
# credential information. We should really capture signals and bind on the
# termination signal to capture all cases. However, this script is meant to be
# run in controlled and automated contexts, so we should be fine.
gcloud_exit() {
    _code=${1:-0}
    if [ -n "$VOLUME" ]; then
        if docker volume ls | grep -q "$VOLUME"; then
            log "Removing Docker volume $VOLUME" gcloud
            docker volume rm "$VOLUME" >/dev/null
        fi
    fi

    exit "$_code"
}

gcloud_abort() {
    warn "$1" gcloud
    gcloud_exit 1
}

# Generate a random string. Takes two params:
# $1 length of string, defaults to 8
# $2 set of characters allowed in string, defaults to lowercase or figures.
gcloud_random() {
    _len=${1:-8}
    _charset=${2:-a-z0-9};  # Default is lower-case only to please Google
    tr -dc "${_charset}" < /dev/urandom | fold -w "${_len}" | head -n 1
}

gcloud_init() {
  # Considder any parameters as options, if relevant.
  gcloud_options "$@"

  if [ -n "$GCLOUD_DOCKER" ] && [ -z "$GCLOUD_KEY" ]; then
    gcloud_abort "You must provide a service account key for authentication"
  fi
  if [ -z "$GCLOUD_PROJECT" ] && [ -n "$GCLOUD_KEY" ]; then
    GCLOUD_PROJECT=$(grep 'project_id"' "$GCLOUD_KEY" | sed -E 's/\s*"project_id"\s*:\s*"([^"]*)".*/\1/')
    log "Extracted project ID $(blue "$GCLOUD_PROJECT") from key file" gcloud
  fi
  [ -z "$GCLOUD_PROJECT" ] && gcloud_abort "You must provide a GCloud project identifier"

  # Create a Docker volume in which we will be storing credentials for the
  # lifetime of the script. This volume is automatically cleaned up on exit.
  if [ -n "$GCLOUD_DOCKER" ]; then
    if ! docker --version 2>&1 >/dev/null; then
      gcloud_abort "You must have an installation of Docker accessible to you"
    fi
    log "Pulling image $(yellow "$GCLOUD_DOCKER") for gcloud operations" gcloud
    docker image pull "$GCLOUD_DOCKER" >/dev/null
    VOLUME="${appname}"-$(gcloud_random)
    log "Creating Docker volume $(yellow "$VOLUME") to temporarily store credentials" gcloud
    docker volume create "$VOLUME" >/dev/null
  fi
}

# This is an internal relay alias against the gcloud command. This script has
# only been tested with a Docker image and running a number of containers, but
# it should be able to run locally also.
gcloud() {
  if [ -z "$VOLUME" ]; then
    gcloud --project "$GCLOUD_PROJECT" $@
  else
    # When running through Docker, we arrange for two volume mounts: The
    # first volume is pointed to where gcloud stores its credentials and
    # configuration so that consecutive calls will keep authorisation data
    # as the phases of the script progress. The second mount recreates the
    # same directory structure as where the key file is located. This is
    # only used at authorisation time, so that the call will look the same
    # with or without docker.
    docker run \
        --rm \
        -v "${VOLUME}:/root/.config/gcloud" \
      "$GCLOUD_DOCKER" \
        gcloud \
          --project "$GCLOUD_PROJECT" \
          $@
  fi
}

# Copy a file into a volume, implicitely using the same Docker image as the one
# used within the remaining of this script to avoid extra downloads. The volume
# is mounted on a directory with random letters to avoid name collisions.
# Arguments are:
# $1: Path to the file (mandatory)
# $2: Name of the destination volume (mandatory)
# $3: Name of the destination file in the volume, defaults to basename of $1
_gcloud_volume_cp() {
    _dst=${3:-$(basename "$1")}
    _dirname=${appname}_$(gcloud_random)
    cat "$1" |
        docker run -i --rm \
            -v "${2}:/${_dirname}" \
            "$GCLOUD_DOCKER" \
            tee "/${_dirname}/${_dst}" >/dev/null
}

# Any use of the gcloud command requires authentication, so we start by doing
# this as soon as possible.
gcloud_login() {
  if [ -n "$GCLOUD_KEY" ]; then
    log "Logging in at GCloud with $(red "$GCLOUD_KEY")" gcloud
    # If running without Docker, we have an empty VOLUME. In that case, we
    # simply authenticate locally. When running Docker, this is more
    # cumbersome... For unknown reasons, it is NOT possible to mount the file
    # into a container to be able to read it from the "gcloud auth" call. While
    # this works at the command line, it does NOT work when automated from
    # machinery. Instead, we copy the file into the temporary volume and
    # authenticate from the copy.
    if [ -z "$VOLUME" ]; then
      if ! gcloud auth activate-service-account \
              --key-file "$GCLOUD_KEY"; then
        gcloud_abort "Could not login at GCloud"
      fi
    else
      # Find name of key file, so we copy into the docker container and keep naming.
      _keyfile=$(basename "$GCLOUD_KEY")

      # Copy the content of the locally available and readable key file into
      # the volume that is designated to carry gcloud-specific configuration
      # data. We encapsulate by prefixing the name of the application to avoid
      # name collisions.
      _gcloud_volume_cp "$GCLOUD_KEY" "${VOLUME}" "${appname}_${_keyfile}"
      # Now login using the copy of the file within the volume.
      if ! docker run --rm \
              -v "${VOLUME}:/root/.config/gcloud" \
              "$GCLOUD_DOCKER" \
              gcloud auth activate-service-account \
                  --key-file "/root/.config/gcloud/${appname}_${_keyfile}" >/dev/null; then
        gcloud_abort "Could not login at GCloud"
      fi
    fi
  fi
}
