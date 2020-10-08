#!/usr/bin/env sh

# Name of the Google SDK Docker image to use. This can in theory be set to an
# empty string, in which case the script will use a local installation of
# gcloud. When no tag is specified, the Docker hub will be queried to detect the
# latest official version, i.e. numbered version, based on alpine.
GCLOUD_DOCKER=${GCLOUD_DOCKER:-google/cloud-sdk}

# Path to the service account key. This needs to be provided when running with
# Docker.
GCLOUD_KEY=${GCLOUD_KEY:-}

# Project at Google. When empty, the default, the name of the project will be
# extracted from the JSON authentication key, if given.
GCLOUD_PROJECT=${GCLOUD_PROJECT:-}

# Name of temporary Docker volume that will be created to store credentials
# between runs, if relevant. When empty, a good name will be generated and the
# volume will be automatically removed at exit.
GCLOUD_VOLUME=${GCLOUD_VOLUME:-}

KEEP_VOLUME=0

appname=${appname:-"gcloud"}

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

      -v | --volume)
        GCLOUD_VOLUME="$2"; shift 2;;
      --volume=*)
        GCLOUD_VOLUME="${1#*=}"; shift 1;;

      -*)
        warn "$1 is not a known option"; shift 2;;

      *)
        break;;
    esac
  done
}

gcloud_regtags() {
  _filter=".*"
  _reg=https://registry.hub.docker.com/
  _pages=
  while [ $# -gt 0 ]; do
    case "$1" in
      -f | --filter)
        _filter=$2; shift 2;;
      --filter=*)
        _filter="${1#*=}"; shift 1;;

      -r | --registry)
        _reg=$2; shift 2;;
      --registry=*)
        _reg="${1#*=}"; shift 1;;

      -p | --pages)
        _pages=$2; shift 2;;
      --pages=*)
        _pages="${1#*=}"; shift 1;;

      --)
        shift; break;;
      -*)
        echo "$1 unknown option!" >&2; return 1;;
      *)
        break;
    esac
  done

  # Decide how to download silently
  download=
  if command -v curl >/dev/null; then
    log "Using curl for downloads" gcloud
    # shellcheck disable=SC2037
    download="curl -sSL"
  elif command -v wget >/dev/null; then
    log "Using wget for downloads" gcloud
    # shellcheck disable=SC2037
    download="wget -q -O -"
  else
    return 1
  fi

  # Library images or user/org images?
  if printf %s\\n "$1" | grep -oq '/'; then
    hub="${_reg%/}/v2/repositories/$1/tags/"
  else
    hub="${_reg%/}/v2/repositories/library/$1/tags/"
  fi

  # Get number of pages
  if [ -z "$_pages" ]; then
    log "Discovering pagination from $hub" gcloud
    first=$($download "$hub")
    count=$(printf %s\\n "$first" | sed -E 's/\{\s*"count":\s*([0-9]+).*/\1/')
    if [ "$count" = "0" ]; then
      warn "No tags, probably non-existing repo" gcloud
      return 0
    else
      log "$count existing tag(s) for $1" gcloud
    fi
    pagination=$(   printf %s\\n "$first" |
                    grep -Eo '"name":\s*"[a-zA-Z0-9_.-]+"' |
                    wc -l)
    _pages=$(( count / pagination + 1))
    log "$_pages pages to download for $1" gcloud
  fi

  # Get all tags one page after the other
  i=0
  while [ "$i" -lt "$_pages" ]; do
    i=$(( i + 1 ))
    log "Downloading page $i / $_pages" gcloud
    page=$($download "$hub?page=$i")
    printf %s\\n "$page" |
        grep -Eo '"name":\s*"[a-zA-Z0-9_.-]+"' |
        sed -E 's/"name":\s*"([a-zA-Z0-9_.-]+)"/\1/' |
        grep -E "$_filter" 2>/dev/null || true
  done
}


# Exit script, making sure to remove the Docker volume that temporarily carried
# credential information. We should really capture signals and bind on the
# termination signal to capture all cases. However, this script is meant to be
# run in controlled and automated contexts, so we should be fine.
gcloud_exit() {
    _code=${1:-0}
    if [ -n "$GCLOUD_VOLUME" ] && [ "$KEEP_VOLUME" = "0" ]; then
        if docker volume ls | grep -q "$GCLOUD_VOLUME"; then
            log "Removing Docker volume $GCLOUD_VOLUME" gcloud
            docker volume rm "$GCLOUD_VOLUME" >/dev/null
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
# shellcheck disable=SC2120
gcloud_random() {
    _len=${1:-8}
    _charset=${2:-"a-z0-9"};  # Default is lower-case only to please Google
    LC_ALL=C tr -dc "${_charset}" </dev/urandom 2>/dev/null | head -c"$((_len*2))" | tr -d '\n' | tr -d '\0' | head -c"$_len"
}

gcloud_init() {
  # Considder any parameters as options, if relevant.
  gcloud_options "$@"

  if [ -n "$GCLOUD_DOCKER" ]; then
    if [ -z "$GCLOUD_KEY" ] && [ -z "$GCLOUD_VOLUME" ]; then
      gcloud_abort "You must provide a service account key, or a previous volume for authentication"
    fi
  fi
  if [ -z "$GCLOUD_PROJECT" ] && [ -n "$GCLOUD_KEY" ]; then
    GCLOUD_PROJECT=$(grep 'project_id"' "$GCLOUD_KEY" | sed -E 's/\s*"project_id"\s*:\s*"([^"]*)".*/\1/')
    log "Extracted project ID $(blue "$GCLOUD_PROJECT") from key file" gcloud
  fi

  # Create a Docker volume in which we will be storing credentials for the
  # lifetime of the script. This volume is automatically cleaned up on exit.
  if [ -n "$GCLOUD_DOCKER" ]; then
    # Check that Docker is installed
    if ! docker --version >/dev/null 2>&1; then
      gcloud_abort "You must have an installation of Docker accessible to you"
    fi

    # Discover latest Google SDK Docker image if no tag specified.
    if ! printf %s\\n "$GCLOUD_DOCKER" | grep -qE ':[a-zA-Z0-9_.-]+$'; then
      log "No tag provided for $GCLOUD_DOCKER, discovering latest..."
      tag=$(gcloud_regtags --pages 2 --filter '[0-9]+(.[0-9]+)*-alpine$' "$GCLOUD_DOCKER" | head -n 1)
      [ -z "$tag" ] && gcloud_abort "Could not discover latest official tag for $GCLOUD_DOCKER!"
      GCLOUD_DOCKER=${GCLOUD_DOCKER}:$tag
    fi

    # Arrange for Docker image to be present
    log "Pulling image $(yellow "$GCLOUD_DOCKER") for gcloud operations" gcloud
    docker image pull "$GCLOUD_DOCKER" >/dev/null

    # Create temporary Docker volume, or make sure that it exists.
    if [ -z "$GCLOUD_VOLUME" ]; then
      GCLOUD_VOLUME="${appname}"-$(gcloud_random)
      log "Creating temporary Docker volume $(yellow "$GCLOUD_VOLUME") to store credentials" gcloud
      docker volume create "$GCLOUD_VOLUME" >/dev/null
      KEEP_VOLUME=0
    elif ! docker volume ls | grep -q "$GCLOUD_VOLUME"; then
      log "Creating persistent Docker volume $(yellow "$GCLOUD_VOLUME") to store credentials" gcloud
      docker volume create "$GCLOUD_VOLUME" >/dev/null
      KEEP_VOLUME=1
    else
      if [ -z "$GCLOUD_PROJECT" ]; then
        _account=$(gcloud info --format='value(config.account)')
        GCLOUD_PROJECT=$(printf %s\\n "$_account" | sed -E 's/^[^@]+@([[:alnum:]-]+).iam.gserviceaccount.com$/\1/g')
        log "Extracted project ID $(blue "$GCLOUD_PROJECT") from account name $_account" gcloud
      fi
      KEEP_VOLUME=1
    fi
  fi

  if [ -z "$GCLOUD_PROJECT" ]; then
    gcloud_abort "You must provide a GCloud project identifier"
  fi
}

# This is an internal relay alias against the gcloud command. This script has
# only been tested with a Docker image and running a number of containers, but
# it should be able to run locally also.
gcloud() {
  # Force prepending of project to options given to gcloud
  if [ -n "$GCLOUD_PROJECT" ]; then
    set -- --project "$GCLOUD_PROJECT" "$@"
  fi

  if [ -z "$GCLOUD_VOLUME" ]; then
    gcloud "$@"
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
        -v "${GCLOUD_VOLUME}:/root/.config/gcloud" \
      "$GCLOUD_DOCKER" \
        gcloud \
          "$@"
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
    
        docker run -i --rm \
            -v "${2}:/${_dirname}" \
            "$GCLOUD_DOCKER" \
            tee "/${_dirname}/${_dst}" <"$1" >/dev/null
}

# Any use of the gcloud command requires authentication, so we start by doing
# this as soon as possible.
gcloud_login() {
  if [ -n "$GCLOUD_KEY" ]; then
    log "Logging in at GCloud with $(red "$GCLOUD_KEY")" gcloud
    # If running without Docker, we have an empty GCLOUD_VOLUME. In that case, we
    # simply authenticate locally. When running Docker, this is more
    # cumbersome... For unknown reasons, it is NOT possible to mount the file
    # into a container to be able to read it from the "gcloud auth" call. While
    # this works at the command line, it does NOT work when automated from
    # machinery. Instead, we copy the file into the temporary volume and
    # authenticate from the copy.
    if [ -z "$GCLOUD_VOLUME" ]; then
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
      _gcloud_volume_cp "$GCLOUD_KEY" "${GCLOUD_VOLUME}" "${appname}_${_keyfile}"
      # Now login using the copy of the file within the volume.
      if ! docker run --rm \
              -v "${GCLOUD_VOLUME}:/root/.config/gcloud" \
              "$GCLOUD_DOCKER" \
              gcloud auth activate-service-account \
                  --key-file "/root/.config/gcloud/${appname}_${_keyfile}" >/dev/null; then
        gcloud_abort "Could not login at GCloud"
      fi
    fi
  fi
}
