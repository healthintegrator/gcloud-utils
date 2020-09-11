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
  instance without formatting. Formatting can be automated through other means, e.g. [primer](https://github.com/efrecon/primer)