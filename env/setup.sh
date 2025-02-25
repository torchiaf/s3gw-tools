#!/bin/bash
# setup.sh - setup a k3s cluster with longhorn and s3gw
# Copyright 2022 SUSE, LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

ghraw="https://raw.githubusercontent.com"
install_s3gw=true
dev_env=false
use_local_image=0
has_image=false
s3gw_image="ghcr.io/aquarist-labs/s3gw:latest"

#this will likely change to have defaults as s3gw_image
use_local_image_s3exp=0
has_image_s3exp=false
s3gw_image_s3exp="ghcr.io/aquarist-labs/s3gw-ui:latest"

function info() {
  echo "[INFO] $*" >/dev/stdout
}

function error() {
  echo "[ERROR] ${@}" >&2
}

function apply() {
  desc=${1}
  yaml=${2}

  [[ -z "${desc}" || -z "${yaml}" ]] && \
    error "Missing parameters to function apply." && \
    exit 1

  echo "${desc}"
  k3s kubectl apply -f ./${yaml} || (
    error "Failed to create ${desc}."
    exit 1
  )
}

function wait_ingresses() {
  echo -n "Waiting for cluster to become ready..."
  ip=""
  until [ -n "${ip}" ]
  do
    echo -n "." && sleep 1;
    ip=$(kubectl get -n s3gw-system ingress s3gw-ingress -o 'jsonpath={.status.loadBalancer.ingress[].ip}');
  done
}

function show_ingresses() {
  ip=$(kubectl get -n s3gw-system ingress s3gw-ingress -o 'jsonpath={.status.loadBalancer.ingress[].ip}');
  echo ""
  echo "Please add the following line to /etc/hosts to be able to access"
  echo "the Longhorn UI and s3gw:"
  echo ""
  echo "${ip}   longhorn.local s3gw.local s3gw-no-tls.local s3gw-ui.local"
  echo ""
  echo "Longhorn UI available at: https://longhorn.local"
  echo "                          https://longhorn.local:30443"
  echo "s3gw available at:        http://s3gw.local"
  echo "                          http://s3gw.local:30080"
  echo "                          https://s3gw.local"
  echo "                          https://s3gw.local:30443"
  echo "                          http://s3gw-no-tls.local"
  echo "                          http://s3gw-no-tls.local:30080"
  echo "s3gw-ui available at:     http://s3gw-ui-no-tls.local"
  echo "                          http://s3gw-ui-no-tls.local:30080"
  echo "                          https://s3gw-ui.local"
  echo "                          https://s3gw-ui.local:30443"
  echo ""
  echo "Note, the UI will not be able to access the RGW AdminOps API when"
  # Check https://github.com/aquarist-labs/s3gw/issues/31 to get more
  # information about the CORS issues.
  echo "using HTTPS and self-signed certificates because of CORS issues."
  echo "To workaround that, please open the URL https://s3gw.local in the"
  echo "browser and accept the SSL certificate before accessing the UI."
  echo ""
}

function install_on_vm() {
  echo "Proceeding to install on a virtual machine..."
  WORKER_COUNT=0
  S3GW_IMAGE=$s3gw_image
  source ./setup-vm.sh build
}

function export_local_image() {
  info "Checking for local s3gw image..."
  img=$(podman images --noheading --sort created s3gw:latest --format '{{.Repository}}:{{.Tag}}' | \
    head -n 1)

  if [[ -z "${img}" ]]; then
    error "Unable to find local s3gw image."
    exit 1
  fi

  rm -rf ./s3gw.ctr.tar
  info "Exporting ${img}..."
  podman image save ${img} -o ./s3gw.ctr.tar || (
    error "Failed to export s3gw image."
    exit 1
  )
}

function import_local_image() {
  info "Importing local s3gw container image..."
  sudo k3s ctr images import ./s3gw.ctr.tar || (
    error "Failed to import local s3gw image."
    exit 1
  )
}

function export_local_ui_image() {
  info "Checking for local s3gw-ui image..."
  img=$(podman images --noheading --sort created s3gw-ui:latest --format '{{.Repository}}:{{.Tag}}' | \
    head -n 1)

  if [[ -z "${img}" ]]; then
    error "Unable to find local s3gw-ui image."
    exit 1
  fi

  rm -rf ./s3gw-ui.ctr.tar
  info "Exporting ${img}..."
  podman image save ${img} -o ./s3gw-ui.ctr.tar || (
    error "Failed to export s3gw-ui image."
    exit 1
  )
}

function import_local_ui_image() {
  info "Importing local s3gw-ui container image..."
  sudo k3s ctr images import ./s3gw-ui.ctr.tar || (
    error "Failed to import local s3gw-ui image."
    exit 1
  )
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dev)
      dev_env=true
      echo "======================================"
      echo "  INSTALLING DEVELOPMENT ENVIRONMENT  "
      echo "======================================"
      echo
      ;;
    --s3gw-image)
      s3gw_image=$2
      has_image=true
      shift 1
      ;;
    --s3gw-image-s3exp)
      s3gw_image_s3exp=$2
      has_image_s3exp=true
      shift 1
      ;;
    --show-ingresses)
      show_ingresses
      exit 0
      ;;
    --vm)
      install_on_vm
      exit 0
      ;;
    --import-local-image)
      export_local_image
      import_local_image
      exit 0
      ;;
    --import-local-ui-image)
      export_local_ui_image
      import_local_ui_image
      exit 0
      ;;
    --no-s3gw)
      install_s3gw=false
      ;;
  esac
  shift
done

if $install_s3gw ; then
  if [[ -z "${s3gw_image}" ]]; then
    error "s3gw image not provided"
    exit 1
  fi

  if $dev_env ; then
    if [[ ! -e "./s3gw.ctr.tar" ]]; then
      export_local_image
    fi
    use_local_image=1
    ! $has_image && s3gw_image="localhost/s3gw:latest"
    echo "Using local s3gw image '${s3gw_image}'."
  fi

  if [[ -z "${s3gw_image_s3exp}" ]]; then
    error "s3gw-ui image not provided"
    exit 1
  fi

  if $dev_env ; then
    if [[ ! -e "./s3gw-ui.ctr.tar" ]]; then
      export_local_ui_image
    fi
    use_local_image_s3exp=1
    ! $has_image_s3exp && s3gw_image_s3exp="localhost/s3gw-ui:latest"
    echo "Using local s3gw-ui image '${s3gw_image_s3exp}'."
  fi
fi

if k3s --version >&/dev/null ; then
  error "K3s already installed, we won't proceed."
  exit 0
fi

echo "Installing K3s..."
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 || (
  error "Failed to install K3s."
  exit 1
)

# https://longhorn.io/docs/1.2.4/deploy/install/#installing-open-iscsi
echo "Installing iscsi..."
k3s kubectl apply \
  -f ${ghraw}/longhorn/longhorn/v1.2.4/deploy/prerequisite/longhorn-iscsi-installation.yaml || (
  error "Failed to install iscsi."
  exit 1
)

echo "Installing Longhorn..."
k3s kubectl apply \
  -f ${ghraw}/longhorn/longhorn/v1.2.4/deploy/longhorn.yaml || (
  error "Failed to install Longhorn."
  exit 1
)

if $install_s3gw ; then
  if [ ${use_local_image} -eq 1 ]; then
    import_local_image
  else
    echo "Pulling s3gw container image..."
    sudo k3s ctr images pull ${s3gw_image} || (
      error "Failed to pull s3gw image ${s3gw_image}."
      exit 1
    )
  fi

  if [ ${use_local_image_s3exp} -eq 1 ]; then
    import_local_ui_image
  else
    echo "Pulling s3gw-ui container image..."
    sudo k3s ctr images pull ${s3gw_image_s3exp} || (
      error "Failed to pull s3gw-ui image ${s3gw_image_s3exp}."
      exit 1
    )
  fi
fi

# Workaround a K8s behaviour that CustomResourceDefinition must be
# established before they can be used by a resource.
# https://github.com/kubernetes/kubectl/issues/1117
# k3s kubectl wait --for=condition=established --timeout=60s crd middlewares.traefik.containo.us
echo -n "Waiting for CRD to be established..."
while [[ $(kubectl get crd middlewares.traefik.containo.us -o 'jsonpath={..status.conditions[?(@.type=="Established")].status}' 2>/dev/null) != "True" ]]; do
  echo -n "." && sleep 1;
done
echo

if $install_s3gw ; then
  s3gw_yaml="s3gw.yaml"
  $dev_env && s3gw_yaml="s3gw-dev.yaml"

  if [[ -e ${s3gw_yaml} ]]; then
    apply "Installing s3gw from spec file at '${s3gw_yaml}'..." ${s3gw_yaml}
  elif [[ -e "generate-spec.sh" ]]; then
    extra=""
    $dev_env && extra="--dev"
    echo "Generating s3gw spec file at '${s3gw_yaml}'..."
    ./generate-spec.sh --output ${s3gw_yaml} ${extra} --ingress ${ingress}
    apply "Installing s3gw from spec file at '${s3gw_yaml}'..." ${s3gw_yaml}
  else
    echo "Installing s3gw..."
    k3s kubectl apply \
      -f ${ghraw}/aquarist-labs/s3gw-tools/main/env/s3gw.yaml || (
      error "Failed to install s3gw."
      exit 1
    )
  fi

  wait_ingresses
  show_ingresses
fi
