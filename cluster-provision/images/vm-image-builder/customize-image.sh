#!/usr/bin/env bash
set -exuo pipefail

function cleanup() {
  echo "[customize-image] cleanup"
  if [ $? -ne 0 ]; then
    rm -f "$CUSTOMIZE_IMAGE_PATH"
  fi

  rm -rf "$CLOUD_INIT_ISO"
  virsh destroy "$DOMAIN_NAME" || true
  virsh undefine "$DOMAIN_NAME" || true
}

SOURCE_IMAGE_PATH=$1
CUSTOMIZE_IMAGE_PATH=$2
CLOUD_CONFIG_PATH=$3

readonly DOMAIN_NAME="provision-vm"
readonly CLOUD_INIT_ISO="cloudinit.iso"

trap 'cleanup' EXIT SIGINT

# Create cloud-init user data ISO
cloud-localds $CLOUD_INIT_ISO "$CLOUD_CONFIG_PATH"

echo "Customize image by booting a VM with
 the image and cloud-init disk
 press ctrl+] to exit"
virt-install \
  --memory 2048 \
  --vcpus 2 \
  --name $DOMAIN_NAME \
  --disk "$SOURCE_IMAGE_PATH",device=disk \
  --disk $CLOUD_INIT_ISO,device=cdrom \
  --os-type generic \
  --virt-type kvm \
  --destroy-on-exit \
  --graphics none \
  --network default \
  --import

virt-sysprep -d $DOMAIN_NAME --operations machine-id,bash-history,logfiles,tmp-files,net-hostname,net-hwaddr,customize --hostname ""

# Remove VM
virsh undefine $DOMAIN_NAME

# Convert image"
qemu-img convert -c -O qcow2 "$SOURCE_IMAGE_PATH" "$CUSTOMIZE_IMAGE_PATH"
