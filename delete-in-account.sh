#!/bin/bash
${TRACE:+set -x}
set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/. >/dev/null 2>&1 && pwd)"
REGION=${AWS_REGION}

function vpcs() {
  aws ec2 describe-vpcs | jq --arg str "$find" -r '.Vpcs[] | {id: .VpcId, name: (.Tags[]? | select(.Key | contains("Name"))|.Value) }'
}

function filtervpc() {
  local str=${1?"error missing filter"}
  vpcs | jq --arg str "${str}" -r 'select( .name | contains($str)) | .id'
}

function aws-un-set {
  unset AWS_SESSION_TOKEN \
        AWS_SECRET_ACCESS_KEY \
        AWS_ACCESS_KEY_ID \
        AWS_SECURITY_TOKEN \
        AWS_EXPIRATION
}

function aws-set-creds {
  export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
  export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
  export AWS_REGION=$(aws configure get region)
}

function aws-un-assume {
  aws-un-set
  [[ -n ${ORIGINAL_AWS_ACCESS_KEY_ID} ]]     && export AWS_ACCESS_KEY_ID=${ORIGINAL_AWS_ACCESS_KEY_ID}
  [[ -n ${ORIGINAL_AWS_SECRET_ACCESS_KEY} ]] && export AWS_SECRET_ACCESS_KEY=${ORIGINAL_AWS_SECRET_ACCESS_KEY}
  [[ -n ${ORIGINAL_AWS_PROFILE} ]]           && export AWS_PROFILE=${ORIGINAL_AWS_PROFILE}
  [[ -n ${ORIGINAL_AWS_REGION} ]]            && export AWS_REGION=${ORIGINAL_AWS_REGION}

  unset ORIGINAL_AWS_ACCESS_KEY_ID
  unset ORIGINAL_AWS_SECRET_ACCESS_KEY
  unset ORIGINAL_AWS_PROFILE
  unset ORIGINAL_AWS_REGION
}

function aws-assume-another-role {
  ROLE_ARN="${1?'please supply role arn'}"
  NEW_AWS_REGION=${2:-${AWS_REGION}}
  # --duration-seconds 25200
  export CREDENTIALS=$( aws sts assume-role --role-arn="${ROLE_ARN}" --role-session-name="$USER")

  export ORIGINAL_AWS_PROFILE=${AWS_PROFILE}
  export ORIGINAL_AWS_REGION=${AWS_REGION}
  export ORIGINAL_AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
  export ORIGINAL_AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
   
  aws-un-set

  export AWS_ACCESS_KEY_ID=$( echo ${CREDENTIALS} | jq -r '.Credentials.AccessKeyId' )
  export AWS_SECRET_ACCESS_KEY=$( echo ${CREDENTIALS} | jq -r '.Credentials.SecretAccessKey' )
  export AWS_SESSION_TOKEN=$( echo ${CREDENTIALS} | jq -r '.Credentials.SessionToken' )
  export AWS_EXPIRATION=$( echo ${CREDENTIALS} | jq -r '.Credentials.Expiration' )
  export AWS_REGION=${NEW_AWS_REGION}
}

function aws-assume-role {
  if [[ -z ${ORIGINAL_AWS_ACCESS_KEY_ID} ]]; then
    aws-un-assume
  fi
  aws-assume-another-role "${1}"
}

if ! command -v aws &>/dev/null; then
    echo "awscli is not installed. Please install it and re-run this script."
    exit 1
fi

usage() {
    echo "$0 --accountid 123456 [--region [region]]"
    exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      export REGION=${2:-}
      shift 2
      ;;
    --accountid)
      ACCOUNT_ID=${2}
      shift 2
      ;;
    -h | --help) usage ;;
    *) shift 1 ;;
  esac
done

if [ -z "${ACCOUNT_ID}" ]; then
    echo "Must specify an account ID"
    exit 1
fi  

aws-assume-role arn:aws:iam::${ACCOUNT_ID}:role/AWSControlTowerExecution
NEW_ACCOUNT=$(aws sts get-caller-identity | jq -r .Account)
if [[ ${NEW_ACCOUNT} != ${ACCOUNT_ID} ]]; then
    echo "ERROR - didn't change account!!!"
    exit 1
else
    echo "Processing ALL VPC's in ${ACCOUNT_ID} and region ${REGION}..."
fi

ALL_VPCS=$( aws ec2 describe-vpcs \
            --query 'Vpcs[].{vpcid:VpcId,name:Tags[?Key==`Name`].Value[]}' \
            --region ${REGION} \
            | jq -r '.[].vpcid' )

for vpcid in ${ALL_VPCS}; do
    ${PROJECT_DIR}/delete_vpc.sh --vpcid ${vpcid} --no-prompt --region ${REGION}
done
