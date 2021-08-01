#!/bin/bash

SCRIPT_PATH=${SCRIPT_PATH:-$(dirname "$(realpath "$0")")}

CONFIGURE_VFS_SCRIPT_PATH="${SCRIPT_PATH}/configure_vfs.sh"
PFS_IN_USE=${PFS_IN_USE:-}

function node::discover_host_pfs() {
  local -r sriov_pfs=( $(find /sys/class/net/*/device/sriov_numvfs) )
  [ "${#sriov_pfs[@]}" -eq 0 ] && echo "FATAL: Could not find available sriov PFs on host" >&2 && return 1

  local pf_name
  local pf_names=()
  for pf in "${sriov_pfs[@]}"; do
    pf_name="${pf%%/device/*}"
    pf_name="${pf_name##*/}"
    if [ $(echo "${PF_BLACKLIST[@]}" | grep "${pf_name}") ]; then
      continue
    fi

    pfs_names+=( $pf_name )
  done

  echo "${pfs_names[@]}"
}

function node::total_vfs_count() {
  local -r node_name=$1
  local -r node_pid=$(docker inspect -f '{{.State.Pid}}' "$node_name")
  local -r pfs_sriov_numvfs=( $(cat /proc/$node_pid/root/sys/class/net/*/device/sriov_numvfs) )
  local total_vfs_on_node=0

  for num_vfs in "${pfs_sriov_numvfs[@]}"; do
    total_vfs_on_node=$((total_vfs_on_node + num_vfs))
  done

  echo "$total_vfs_on_node"
}

function node::configure_vf_driver() {
  local -r vf_sys_device=$1
  local -r driver=$2

  vf_pci_address=$(basename $vf_sys_device)
  # Check if a VF is bound to a different driver
  if [ -d "$vf_sys_device/driver" ]; then
    vf_bus_pci_device_driver=$(readlink -e $vf_sys_device/driver)
    vf_driver_name=$(basename $vf_bus_pci_device_driver)

    # Check if VF already configured with supported driver
    if [[ $vf_driver_name == $driver ]]; then
      return
    else
      echo "Unbind VF $vf_pci_address from $vf_driver_name driver"
      echo "$vf_pci_address" >> "$vf_bus_pci_device_driver/unbind"
    fi
  fi

  echo "Bind VF $vf_pci_address to $driver driver"
  echo "$driver" >> "$vf_sys_device/driver_override"
  echo "$vf_pci_address" >> "/sys/bus/pci/drivers/$driver/bind"
  echo "" >> "$vf_sys_device/driver_override"

  return 0
}

function node::create_vfs() {
  local -r pf_net_device=$1
  local -r vfs_count=$2

  local -r pf_name=$(basename $pf_net_device)
  local -r pf_sys_device=$(readlink -e $pf_net_device)

  local -r sriov_totalvfs_content=$(cat $pf_sys_device/sriov_totalvfs)
  [ $sriov_totalvfs_content -lt $vfs_count ] && \
    echo "FATAL: PF $pf_name, VF's count should be up to sriov_totalvfs: $sriov_totalvfs_content" >&2 && return 1

  local -r sriov_numvfs_content=$(cat $pf_sys_device/sriov_numvfs)
  if [ $sriov_numvfs_content -ne $vfs_count ]; then
    echo "Creating $vfs_count VF's on PF $pf_name"
    echo 0 >> "$pf_sys_device/sriov_numvfs"
    echo "$vfs_count" >> "$pf_sys_device/sriov_numvfs"
    sleep 3
  fi

  return 0
}
