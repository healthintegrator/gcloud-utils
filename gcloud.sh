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

# Dynamic vars
cmdname=$(basename "$(readlink -f "$0")")
# shellcheck disable=SC2034
appname=${cmdname%.*};  # Used in logging

# Print usage on stderr and exit
usage() {
  exitcode="$1"
  cat << USAGE >&2

Description:

  $cmdname logs in at Google Compute Engine and execute a command. This is
  done through a Docker container.

Usage:
  $cmdname [-option arg --long-option(=)arg]

  where all dash-led options are as follows (long options can be followed by
  an equal sign):
    --silent        Be as silent as possible
    -k | --key      Path to service account key file (JSON)
    -p | --project  Google Cloud project to run against. When empty, the
                    default, will be guessed from key or volume with credentials
    --docker        Fully qualified Docker image to use for gcloud. When no
                    tag, the default, the latest will be guessed and used. When
                    empty, the local gcloud installation will be used.
    --volume        Name of Docker volume to store credentials in. When empty,
                    the default, a temporary volume will be used


Details:
  In most cases, you will only have to specify the path to the service account
  key.

  If you want to perform several operations in a row, you can specify any Docker
  volume name. If the volume does not exist, it will be created and filled in
  with credentials information. Upon consecutive operations, you will only have
  to specify the name of the volume (and not the service account key). Once done
  you will have to remove the volume.

  As guessing the tags for the Docker image to use can take (network) time, it
  is a good idea to fix the Docker image when performing successive operations.

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
            GCLOUD_KEY=$2; shift 2;;
        --key=*)
            # shellcheck disable=SC2034
            GCLOUD_KEY="${1#*=}"; shift 1;;

        -p | --project)
            GCLOUD_PROJECT=$2; shift 2;;
        --project=*)
            # shellcheck disable=SC2034
            GCLOUD_PROJECT="${1#*=}"; shift 1;;

        --docker)
            GCLOUD_DOCKER=$2; shift 2;;
        --docker=*)
            # shellcheck disable=SC2034
            GCLOUD_DOCKER="${1#*=}"; shift 1;;

        --volume)
            GCLOUD_VOLUME=$2; shift 2;;
        --volume=*)
            # shellcheck disable=SC2034
            GCLOUD_VOLUME="${1#*=}"; shift 1;;

        --silent)
            # shellcheck disable=SC2034
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

gcloud_init
gcloud_login

# Execute gcloud command with arguments and capture exit code.
set +e
gcloud "$@"
_code=$?
set -e

# Cleanup and exit with same code as gcloud
gcloud_exit "$_code"
