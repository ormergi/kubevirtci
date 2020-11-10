#!/usr/bin/env bash

# Source:
# https://github.com/stackrox/admission-controller-webhook-demo/blob/master/deployment/generate-keys.sh
# 
# This script is targeted for those who want to generate self-signed certificates
# in order to sign Kubernetes webhhoks.
# 
# Arguments Expected:
#   namespace - namespace of the webhhok, also part of CN
#   hook_name - webhook name also the name of the files that will be crated, also part of CN
#
# Cetificate generating process:
#   Generates a self-signed CA certificate, server certificate and server private-key 
#   to be used by the a webhook server.
#   The certificate will be issued for the Common Name (CN) of '${hook_name}-service.${namespace}.svc', 
#   which is the cluster-internal DNS name for the service.
# 
# This script also checks if openssl is installed if not use docker container https://hub.docker.com/r/frapsoft/openssl
#    
# Generates files: 
#   Private Key of the webhhok server - ${hook_name}.key
#   Certificate signed with the private key of the CA -${hook_name}.cert

CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_SRL="ca.srl"
PK_CSR="ca-key-csr.csr"

function _openssl {
  docker run --rm --privileged -v ${PWD}:/export -w /export frapsoft/openssl "$@"
}

function cleanup() {
  echo "rm -f $CA_KEY $CA_CRT $CA_SRL $PK_CSR"
}

set -exuo pipefail

namespace="$1"
hook_name="$2"

private_key_file_name="${hook_name}.key"
certificate_file_name="${hook_name}.cert"
common_name="${hook_name}-service.${namespace}.svc"

trap 'cleanup' EXIT SIGINT

if [ -z "$(rpm -aq openssl)" ]; then
  if [ -z "$(rpm -aq docker )" ]; then
    echo "could not find docker installation in order to use openssl container" && exit 1  
  fi
  openssl=_openssl
fi

# Generate the CA cert and private key
$openssl req -nodes -new -x509 -keyout $CA_KEY -out $CA_CRT -days 365 -set_serial 2020 -subj "/O=kubvirt.io"

# Generate the private key for the webhook server
$openssl genrsa -out $private_key_file_name 4096 

# Generate a Certificate Signing Request (CSR) for the private key, 
$openssl req -new -key $private_key_file_name -out $PK_CSR -subj "/O=kubvirt.io /CN=${common_name}" 

# Sign certificate it with the private key of the CA.
$openssl x509 -req -in $PK_CSR -CA $CA_CRT -CAkey $CA_KEY -CAcreateserial -days 365 -set_serial 2020 -out $certificate_file_name
