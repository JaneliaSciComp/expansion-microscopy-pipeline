DIR=$(cd "$(dirname "$0")"; pwd)

source ${DIR}/container-versions.sh

docker push registry.int.janelia.org/exm-analysis/synapse:${synapse-version}
docker push registry.int.janelia.org/exm-analysis/synapse-dask:${synapse-dask-version}
