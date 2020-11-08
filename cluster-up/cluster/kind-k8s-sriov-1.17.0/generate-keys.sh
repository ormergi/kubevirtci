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

CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_SRL="ca.srl"

function cleanup() {
  echo " rm -f $CA_KEY $CA_CRT $WEBHOOKS_SERVER_CERT $CA_SRL"
}

set -exuo pipefail

namespace="$1"
hook_name="$2"

private_key_file_name="${hook_name}.key"
certificate_file_name="${hook_name}.cert"
common_name="${hook_name}-service.${namespace}.svc"

trap 'cleanup' EXIT SIGINT

# Generate the CA cert and private key
openssl req -nodes -new -x509 -keyout $CA_KEY -out $CA_CRT -subj "/CN=${hook_name}Admission Controller Webhook CA"

# Generate the private key for the webhook server
openssl genrsa -out $private_key_file_name 2048

# Generate a Certificate Signing Request (CSR) for the private key, and sign it with the private key of the CA.
openssl req -new -key $private_key_file_name -subj "/CN=${common_name}" \
    | openssl x509 -req -CA $CA_CRT -CAkey $CA_KEY -CAcreateserial -out $certificate_file_name
