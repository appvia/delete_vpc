#!/bin/bash
${TRACE:+set -x}
set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/. >/dev/null 2>&1 && pwd)"

log() { (echo 2>/dev/null -e "$@"); }
info() { log "[info]  $@"; }
error() {
  log "[error] $@"
  exit 1
}

usage() {
    echo "$0 --product-name catalog-for-someaccount [--region [region]]"
    exit 0
}

terminate() {
    local ppn=${1?"missing product name"}
    aws servicecatalog terminate-provisioned-product \
             --provisioned-product-name ${ppn} >/dev/null
    return $?
}

status() {
    local ppn=${1?"missing product name"}
    aws servicecatalog describe-provisioned-product \
           --name ${ppn} \
           | jq -r .ProvisionedProductDetail.Status
    return $?
}

statusDetail() {
    local ppn=${1?"missing product name"}
    aws servicecatalog describe-provisioned-product \
           --name ${ppn} \
           | jq -r .ProvisionedProductDetail.StatusMessage
    return $?
}

if ! command -v aws &>/dev/null; then
    error "awscli is not installed. Please install it and re-run this script."
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-name)
      PPN=${2}
      shift 2
      ;;
    --account-name)
      ACCOUNT_NAME=${2}
      shift 2
      ;;
    -h | --help) usage ;;
    *) shift 1 ;;
  esac
done

if [ ! -z ${ACCOUNT_NAME} ]; then
    PPN="catalog-for-${ACCOUNT_NAME}"
    log "checking for provisioned product name ${PPN}"
    if ! status ${PPN} &>/dev/null ; then
        error "cannot find product"
    fi
fi

if [ -z ${PPN} ]; then
    error "invalid product name"
fi

info "attempting delete of provisioned product name ${PPN}"
while :
do
    if ! STATUS=$(status ${PPN}) ; then
        error "unable to get status - probs allready deleted"
    fi
    case "${STATUS}" in
    TAINTED)
        detail=$(statusDetail ${PPN})
        if echo "${detail}" | grep "ResourceNotFoundException" ; then
            info "${PPN} - account already closed"
            exit 0
        fi
        if echo ${detail} | grep "unable to assume the AWSControlTowerExecution role in the account" ; then
            error "${PPN} - unable to access account as already probs closed?"
        fi
        if [[ "${detail}" == "Unable to terminate provisioned product. The corresponding Control Tower account is suspended." ]]; then
            error "${PPN} - account already closed, suspended"
        fi
        info "${PPN} - retrying - as status message is ${detail}"
        terminate ${PPN}
        ;;
    CREATED|AVAILABLE)
        # terminate or try again
        terminate ${PPN}
        ;;
    UNDER_CHANGE)
        # wait
        ;;
    *)
        info "${PPN} - unknonw status is ${STATUS}... trying again - may need to check me"
        ;;
    esac
    sleep 3
done
