#!/bin/bash
${TRACE:+set -x}
set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/. >/dev/null 2>&1 && pwd)"

if ! command -v aws &>/dev/null; then
    echo "awscli is not installed. Please install it and re-run this script."
    exit 1
fi

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
    echo "checking for provisioned product name ${PPN}"
    if ! status ${PPN} &>/dev/null ; then
        echo "cannot find product"
        exit 1
    fi
fi

if [ -z ${PPN} ]; then
    echo "invalid product name"
    exit 1
fi

echo "attempting delete of provisioned product name ${PPN}"
while :
do
    if ! STATUS=$(status ${PPN}) ; then
        echo "unable to get status - probs allready deleted"
        exit 1
    fi
    case "${STATUS}" in
    TAINTED)
        detail=$(statusDetail ${PPN})
        if echo ${detail} | grep "unable to assume the AWSControlTowerExecution role in the account" ; then
            echo "unable to access account as already probs closed?"
            exit 1
        fi
        if [[ "${detail}" == "Unable to terminate provisioned product. The corresponding Control Tower account is suspended." ]]; then
            echo "account already closed"
            exit 1
        fi
        echo "retrying - as status message is ${detail}"
        terminate ${PPN}
        ;;
    CREATED)
        # terminate or try again
        terminate ${PPN}
        ;;
    UNDER_CHANGE)
        # wait
        ;;
    *)
        echo "status is ${STATUS}... trying again - may need to check me"
        ;;
    esac
    sleep 3
done
