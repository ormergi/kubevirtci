#!/usr/bin/env bash

set -ex

source ${KUBEVIRTCI_PATH}/cluster/ephemeral-provider-common.sh

function up() {
    # stage 1
    if [ "$KUBEVIRT_WITH_SRIOV" == "true" ]; then
        export KUBEVIRT_NUM_NODES=1
        export KUBEVIRT_MEMORY_SIZE=8G
        export VFS_DRIVER="vfio-pci"
        export KUBEVIRT_SRIOV_DEVICES_PER_NODE="${KUBEVIRT_SRIOV_DEVICES_PER_NODE:-5}"
        
        # create and configure vfs on host
        source "${KUBEVIRTCI_PATH}/cluster/${KUBEVIRT_PROVIDER}/sriov-node/node.sh"
        pfs_names=($(node::discover_host_pfs))
        pfs_names="${pfs_names[@]:0:$KUBEVIRT_NUM_NODES}"
        [ ${#pfs_names[@]} -lt $KUBEVIRT_NUM_NODES ] && echo "FATAL: there are not enough PF's" && exit 1
        
        vfs=()
        for i in $(seq $KUBEVIRT_NUM_NODES); do  
            pf="${pf_names[$i]}"
        
            node::create_vfs "/sys/class/net/$pf/device" "$KUBEVIRT_SRIOV_DEVICES_PER_NODE"
            
            # configure driver
            vfs_sys_devices=($(find /sys/class/net/$pf/device/virtfn*))
            for vf_device in "${vfs_sys_devices[@]}"; do
                node::configure_vf_driver "$(readlink -e $vf_device)" "$VFS_DRIVER"
            done

            # configure vfs
            for i in $(seq $KUBEVIRT_SRIOV_DEVICES_PER_NODE); do
                ip link set dev $pf vf $((i-1)) state enable
                ip link set dev $pf vf $((i-1)) mac "02:00:00:00:00:0$i"
            done
            
            # get vfs addresses
            vfs+=($(realpath /sys/class/net/$pf/device/virtfn[0-${KUBEVIRT_SRIOV_DEVICES_PER_NODE}] | xargs -I{}  basename {}))
        done
        # format vfs addresses to be comma separated
        vfs="${vfs[@]}"
        vfs="${vfs// /,}"
        export KUBEVIRT_SRIOV_PCI_ADDRESSES=""${vfs}""
    fi

    params=$(echo $(_add_common_params))
    if [[ ! -z $(echo $params | grep ERROR) ]]; then
        echo -e $params
        exit 1
    fi
    eval ${_cli} run $params

    # Copy k8s config and kubectl
    ${_cli} scp --prefix $provider_prefix /usr/bin/kubectl - >${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubectl
    chmod u+x ${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubectl
    ${_cli} scp --prefix $provider_prefix /etc/kubernetes/admin.conf - >${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubeconfig

    # Set server and disable tls check
    export KUBECONFIG=${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubeconfig
    ${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubectl config set-cluster kubernetes --server=https://$(_main_ip):$(_port k8s)
    ${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true

    # Make sure that local config is correct
    prepare_config


    kubectl="${_cli} --prefix $provider_prefix ssh node01 -- sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

    # For multinode cluster Label all the non master nodes as workers,
    # for one node cluster label master with 'master,worker' roles
    if [ "$KUBEVIRT_NUM_NODES" -gt 1 ]; then
        label="!node-role.kubernetes.io/master"
    else
        label="node-role.kubernetes.io/master"
    fi
    $kubectl label node -l $label node-role.kubernetes.io/worker=''

    # Activate cluster-network-addons-operator if flag is passed
    if [ "$KUBEVIRT_WITH_CNAO" == "true" ] || [ "$KUBVIRT_WITH_CNAO_SKIP_CONFIG" == "true" ]; then

        $kubectl create -f /opt/cnao/namespace.yaml
        $kubectl create -f /opt/cnao/network-addons-config.crd.yaml
        $kubectl create -f /opt/cnao/operator.yaml
        $kubectl wait deployment -n cluster-network-addons cluster-network-addons-operator --for condition=Available --timeout=200s

        if [ "$KUBVIRT_WITH_CNAO_SKIP_CONFIG" != "true" ]; then

            $kubectl create -f /opt/cnao/network-addons-config-example.cr.yaml
            $kubectl wait networkaddonsconfig cluster --for condition=Available --timeout=200s
        fi
    fi

    if [ "$KUBEVIRT_DEPLOY_ISTIO" == "true" ] && [[ $KUBEVIRT_PROVIDER =~ k8s-1\.1.* ]]; then
        echo "ERROR: Istio is not supported on kubevirtci version < 1.20"
        exit 1

    elif [ "$KUBEVIRT_DEPLOY_ISTIO" == "true" ]; then
        if [ "$KUBEVIRT_WITH_CNAO" == "true" ]; then
            $kubectl create -f /opt/istio/istio-operator-with-cnao.cr.yaml
        else
            $kubectl create -f /opt/istio/istio-operator.cr.yaml
        fi
        
        istio_operator_ns=istio-system
        retries=0
        max_retries=20
        while [[ $retries -lt $max_retries ]]; do
            echo "waiting for istio-operator to be healthy"
            sleep 5
            health=$(kubectl -n $istio_operator_ns get istiooperator istio-operator -o jsonpath="{.status.status}")
            if [[ $health == "HEALTHY" ]]; then
                break
            fi
            retries=$((retries + 1))
        done
        if [ $retries == $max_retries ]; then
            echo "waiting istio-operator to be healthy failed"
            exit 1
        fi
    fi
    
    # stage 2
    if [ "$KUBEVIRT_WITH_SRIOV" == "true" ]; then
        kubectl="${KUBEVIRTCI_CONFIG_PATH}/$KUBEVIRT_PROVIDER/.kubectl"
        source "${KUBEVIRTCI_PATH}/cluster/${KUBEVIRT_PROVIDER}/sriov-components/sriov_components.sh"
        # label sriov capabel nodes
        SRIOV_NODE_LABEL_KEY="sriov_capable"
        SRIOV_NODE_LABEL_VALUE="true"
        for node in $($kubectl get no --no-headers | awk '{print $1}'); do
            $kubectl label nodes $node "${SRIOV_NODE_LABEL_KEY}=${SRIOV_NODE_LABEL_VALUE}"
        done
        
        # deploy sriov components
        sriov_components::deploy_multus
        sriov_components::deploy \
            "$VFS_DRIVER" \
            "kubevirt.io" "sriov_net" \
            "$SRIOV_NODE_LABEL_KEY" "$SRIOV_NODE_LABEL_VALUE"
    fi
}
