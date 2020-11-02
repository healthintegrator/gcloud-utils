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

  $cmdname logs in at Google Compute Engine and creates a resource if it does
  not already exist. This is done through a Docker container.

Usage:
  $cmdname [-option arg --long-option(=)arg] [--] group command resource (options)

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

  And arguments following the optional double dash are as follows:
    group      Section/group of the gcloud CLI, e.g. compute, docker, etc.
    command    Command under that group, e.g. disks, firewall-rules, etc.
    resource   Name of the resource to create
    options    All other options are blindly passed to create


Details:
  This is a wrapper around list/create for a wide number of resources that can
  be handled by the gcloud CLI. The wrapper will first execute
  gcloud <group> <command> list and check if the output contains the name of the
  <resource>. If not, it will call gcloud <group> <command> create <resource>,
  followed by all the options that were specified at the command-line.

  In effect, this will check if a resource already exist, and will create it if
  it does not. This supposes that the command group implements list for listing
  out resources and create for creating resources, which gcloud CLI does in most
  cases.

Example:
  Provided a service account key in JSON format at svc.json, the following
  command would create a firewall rule called alt-http for the alternative web
  port if it did not already exist under that name:

  gcloud-ifcreate.sh -k svc.json \
      compute firewall-rules alt-http \
          --allow=tcp:8080 \
          --direction=INGRESS

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

if [ "$#" -lt "3" ]; then
  gcloud_abort "You need at least a section, a (resource) type and resource name!"
fi

GROUP=$1;    # e.g. compute
CMD=$2;      # e.g. disks, firewall-rules, etc.
RESOURCE=$3; # Name of the resource to create if it does not exist
shift 3

gcloud_init
gcloud_login

_code=0
if gcloud "$GROUP" "$CMD" list 2>/dev/null | tail -n +2 | grep -q "$RESOURCE"; then
  log "Resource $GROUP/$CMD/$RESOURCE seems to already exist"
else
  # Execute gcloud command with arguments and capture exit code.
  set +e
  gcloud "$GROUP" "$CMD" create "$RESOURCE" "$@"
  _code=$?
  set -e
fi

# Cleanup and exit with same code as gcloud
gcloud_exit "$_code"
