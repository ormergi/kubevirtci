#!/bin/bash

set -ex

pci_address_regex="[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}.\d{1}"

if [ "$1" != "--vendor" ]; then
    echo "No vendor provided"
    exit 1
fi
vendor=$2

MDRIVDER="${MDRIVDER:-vfio-pci}"

function get_device_driver() {
    local dev_driver=$(readlink $driver_path)
    echo "${dev_driver##*/}"
}

# load the vfio-pci module
modprobe -i "${MDRIVDER}"

# find the PCI address of the device by vendor_id:product_id
pci_address=(`lspci -D -d ${vendor} | grep -Po "$pci_address_regex"`)
for pci_address in "${pci_address[@]}"; do
    dev_sysfs_path="/sys/bus/pci/devices/$pci_address"

    if [ ! -d $dev_sysfs_path ]; then
        echo "Error: PCI address ${pci_address} does not exist!" 1>&2
        continue
    fi

    if [ ! -d "$dev_sysfs_path/iommu/" -a "$MDRIVDER" == "vfio-pci" ]; then
        echo "Error: No vIOMMU found in the VM $pci_address" 1>&2
        continue
    fi

    # set device driver path
    driver_path="${dev_sysfs_path}/driver"
    driver_override="${dev_sysfs_path}/driver_override"

    driver=$(get_device_driver)

    if [ "$driver" != "${MDRIVDER}" ]; then

        # unbind from the original device driver
        if [ -f "${driver_path}/unbind" ]; then 
            echo "${pci_address}" > "${driver_path}/unbind"
        fi
        # bind the device to driver
        echo "${MDRIVDER}" > "${driver_override}"
        echo "${pci_address}"> "/sys/bus/pci/drivers/${MDRIVDER}/bind"
    fi

    # The device should now be using the vfio-pci driver
    new_driver=$(get_device_driver)
    if [ "$new_driver" != "${MDRIVDER}" ]; then
        echo "Error: Failed to bind to $MDRIVDER driver $pci_address" 1>&2
        continue
    fi
done
