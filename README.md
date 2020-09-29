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

* [gcloud-disk](./gcloud-disk.sh) will create a disk and attach it to a virtual
  instance without formatting. Formatting can be automated through other means,
  e.g. [primer](https://github.com/efrecon/primer)
* [gcloud-tags](./gcloud-tags.sh) will add network tags to an instance if they
  do not already exist.

The utilities are constructed on top of a library aiming at hiding most of the
`gcloud` calling details. The library is able to detect the latest numbered
version of the Docker image for the `gcloud` CLI, or handles login using a
separate transient Docker volume.
