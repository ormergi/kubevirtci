#!/usr/bin/env bash

set -e

DOCKER="${CONTAINER_RUNTIME:-docker}"

export CLUSTER_NAME="sriov"
export KIND_NODE_IMAGE="v1.17.11@sha256:5240a7a2c34bf241afb54ac05669f8a46661912eab05705d660971eeb12f6555"

source ${KUBEVIRTCI_PATH}/cluster/kind/common.sh

function up() {
    if [[ "$KUBEVIRT_NUM_NODES" -ne 2 ]]; then
        echo 'SR-IOV cluster can be only started with 2 nodes'
        exit 1
    fi

    # print hardware info for easier debugging based on logs
    echo 'Available NICs'
    docker run --rm --cap-add=SYS_RAWIO quay.io/phoracek/lspci@sha256:0f3cacf7098202ef284308c64e3fc0ba441871a846022bb87d65ff130c79adb1 sh -c "lspci | egrep -i 'network|ethernet'"

    cp $KIND_MANIFESTS_DIR/kind.yaml ${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/kind.yaml
    _fetch_kind
    prepare_workers
    # adding mounts to control plane, need them for sriov
    cat >> ${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/kind.yaml << EOF 
  extraMounts:
  - containerPath: /lib/modules
    hostPath: /lib/modules
    readOnly: true
  - containerPath: /dev/vfio/
    hostPath: /dev/vfio/
EOF

    setup_kind

    # remove the rancher.io kind default storageClass
    _kubectl delete sc stand

    nodes=$(_kubectl get nodes -o=custom-columns=:.metadata.name | awk NF)
    for node in $nodes; do
        # Create local-volume directories, which, on other providers, are pre-provisioned.
        # For more info, check https://github.com/kubevirt/kubevirtci/blob/master/cluster-provision/STORAGE.md
        for i in {1..10}; do
            mount_disk $node $i
        done
        $DOCKER exec $node bash -c "chmod -R 777 /var/local/kubevirt-storage/local-volume"

        # Create a unique UUID file reference file for each node, that will be mounted in order to support
        # Migration in Kind providers.
        $DOCKER exec $node bash -c 'cat /proc/sys/kernel/random/uuid > /kind/product_uuid'
    done

    # create the `local` storage class - which functional tests assume to exist
    _kubectl apply -f $KIND_MANIFESTS_DIR/local-volume.yaml

    # Since Kind provider uses containers as nodes, the UUID on all of them will be the same,
    # and Migration by libvirt would be blocked, because migrate between the same UUID is forbidden.
    # Enable PodPreset so we can use it in order to mount a fake UUID for each launcher pod.
    $DOCKER exec kind-1.17.0-control-plane bash -c 'sed -i \
    -e "s/NodeRestriction/NodeRestriction,PodPreset/" \
    -e "/NodeRestriction,PodPreset/ a\    - --runtime-config=settings.k8s.io/v1alpha1=true" \
    /etc/kubernetes/manifests/kube-apiserver.yaml'

    # Configure SRIOV VF's and deploy SRIOV operator
    ${KUBEVIRTCI_PATH}/cluster/$KUBEVIRT_PROVIDER/config_sriov.sh
}

function mount_disk() {
    local node=$1
    local idx=$2
    $DOCKER exec $node bash -c "mkdir -p /var/local/kubevirt-storage/local-volume/disk${idx}"
    $DOCKER exec $node bash -c "mkdir -p /mnt/local-storage/local/disk${idx}"
    $DOCKER exec $node bash -c "mount -o bind /var/local/kubevirt-storage/local-volume/disk${idx} /mnt/local-storage/local/disk${idx}"
}
