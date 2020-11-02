# gcloud-utils

This project, still at its infancy, provides wrappers and utilities around the
[`gcloud`][gcloud] command-line to automate operations (in a repeatable fashion)
from scripts and initialisation tools of various sorts, e.g. [machinery]. Most
utilities do not require an installation of [`gcloud`][gcloud] itself, they will
default to running it from [docker][gcloud-docker]

  [gcloud]: https://cloud.google.com/sdk/gcloud
  [machinery]: https://github.com/efrecon/machinery
  [gcloud-docker]: https://hub.docker.com/r/google/cloud-sdk/

At present, the utilities are:

* [gcloud-disk.sh](./gcloud-disk.sh) will create a disk and attach it to a
  virtual instance without formatting. Formatting can be automated through other
  means, e.g. [primer](https://github.com/efrecon/primer)
* [gcloud-tags.sh](./gcloud-tags.sh) will add network tags to an instance if
  they do not already exist.
* [gcloud.sh](./gcloud.sh) is a Docker wrapper around the regular `gcloud`. It
  will login using the service account key passed as argument and call `gcloud`
  with the arguments passed at the command-line. It uses a (temporary) volume
  for authentication credentials, but is able to reuse a named volume between
  calls when such a volume name is passed as an argument.
* [gcloud-ifcreate.sh](./gcloud-ifcreate.sh) is a Docker wrapper around all
  `gcloud` CLI commands that support the `list`/`create` operations. It will
  list resources, looking for an existing one with the name passed at the CLI,
  and create it if it did not exist without generating any error.

The utilities are constructed on top of a library aiming at hiding most of the
`gcloud` calling details. The library is able to detect the latest numbered
version of the Docker image for the `gcloud` CLI, or handles login using a
separate transient Docker volume. The library is able to reuse the Docker volume
between runs to avoid re-authenticating several times. In that case, it is up to
the caller to remove the Docker volume once all operations have been performed.
