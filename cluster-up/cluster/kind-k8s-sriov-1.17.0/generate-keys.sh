#!/usr/bin/env bash

# Copyright (c) 2019 StackRox Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# generate-keys.sh
#
# Generate a (self-signed) CA certificate and a certificate and private key to be used by the webhook demo server.
# The certificate will be issued for the Common Name (CN) of `webhook-server.webhook-demo.svc`, which is the
# cluster-internal DNS name for the service.
#

function _openssl {
  docker run --rm --privileged -v ${PWD}:/export -w /export frapsoft/openssl "$@"
}

CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_SRL="ca.srl"
PK_CSR="ca-key-csr.csr"

function cleanup() {
  rm -f $CA_KEY $CA_CRT $CA_SRL $PK_CSR
}

set -exuo pipefail

namespace="$1"
hook_name="$2"

private_key_file_name="${hook_name}.key"
certificate_file_name="${hook_name}.cert"
common_name="${hook_name}-service.${namespace}.svc"

trap 'cleanup' EXIT SIGINT

if [ -z "$(rpm -aq openssl)" ]; then
  openssl=_openssl
fi

# Generate the CA cert and private key
$openssl req -nodes -new -x509 -subj "/CN=${hook_name}Admission Controller Webhook CA"  -keyout $CA_KEY -out $CA_CRT

# Generate the private key for the webhook server
$openssl genrsa 2048 -out $private_key_file_name

# Generate a Certificate Signing Request (CSR) for the private key, 
$openssl req -new -key $private_key_file_name -subj "/CN=${common_name}" -out $PK_CSR

# Sign certificate it with the private key of the CA.
$openssl x509 -req -in $PK_CSR -CA $CA_CRT -CAkey $CA_KEY -CAcreateserial -out $certificate_file_name
