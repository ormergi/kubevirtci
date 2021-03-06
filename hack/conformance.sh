#!/bin/bash

set -xeuo pipefail

ARTIFACTS=${ARTIFACTS:-${PWD}}
sonobuoy_version=0.18.2
config_file=${1:-}

if [[ -z "$KUBEVIRT_PROVIDER" ]]; then
    echo "KUBEVIRT_PROVIDER is not set" 1>&2
    exit 1
fi

export KUBECONFIG=$(cluster-up/kubeconfig.sh)

teardown() {
    rv=$?
    ./sonobuoy status --json
    ./sonobuoy logs > ${ARTIFACTS}/sonobuoy.log
    results_tarball=$(./sonobuoy retrieve)
    tar -xvzf $results_tarball plugins/e2e/results/
    cp -f $(find plugins/e2e/results/* -name "*.xml") ${ARTIFACTS}/

    if [ $rv -ne 0 ]; then
        echo "error found, exiting"
        exit $rv
    fi

    passed=$(./sonobuoy status --json | jq  ' .plugins[] | select(."result-status" == "passed")'  | wc -l)
    failed=$(./sonobuoy status --json | jq  ' .plugins[] | select(."result-status" == "failed")'  | wc -l)

    if [ $passed -eq 0 ] || [ $failed -ne 0 ]; then
        echo "sonobuoy failed"
        exit 1
    fi
}

curl -L https://github.com/vmware-tanzu/sonobuoy/releases/download/v${sonobuoy_version}/sonobuoy_${sonobuoy_version}_linux_amd64.tar.gz | tar -xz

trap teardown EXIT

run_cmd="./sonobuoy run --wait"

if [ "$config_file" != "" ]; then
    run_cmd+=" --config $config_file"
fi

$run_cmd
