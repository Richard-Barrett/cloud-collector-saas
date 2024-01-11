#!/bin/bash


##########################################################################################

# Instructions:

#

# - Start a Cloud Shell session form the AWS UI

#

# - Upload this script to the shell

#

# - Make this script executable:

#   chmod +x resource-count-aws.sh

#

# - Run this script:

#   resource-count-aws.sh

#   resource-count-aws.sh org (see below)

#

# API/CLI used:

#

# - aws organizations describe-organization (optional)

# - aws organizations list-accounts (optional)

# - aws sts assume-role (optional)

#

# - aws aws sts get-caller-identity

# - aws iam list-account-aliases

#

# - aws ec2 describe-regions

# - aws ec2 describe-instances

# - aws lambda get-account-settings

# - aws ecs list-clusters

# - aws eks list-clusters

#

# Organization Support

#

# The script can collect sizing information for AWS accounts attached to an AWS Organization by specifying `org` as a parameter.

#

# It does this by leveraging the AWS `OrganizationAccountAccessRole`

#

# https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_access.html

#

# Flow and logic for AWS Organizations:

#

# 1. Queries for member accounts using the Organizations API

# 2. Loops through each member account

# 3. Authenticates into each member account via STS Assume Role into the `OrganizationAccountAccessRole` with the minimum session duration possible (900 seconds)

# 4. Counts resources

#

# The `OrganizationAccountAccessRole` is automatically created in an account if the account was provisioned via the organization.

# If the account was not originally provisioned in that manner, the role may not exist and assuming the role may fail.

# Administrators can create the role manually by following this documentation:

#

# https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_access.html

#

# Sample IAM Policy for this script:

#

# {

#   "Version": "2012-10-17",

#   "Statement": [

#     {

#       "Sid": "Rapid7ICSAWSResourceScanPolicy",

#       "Effect": "Allow",

#       "Action": [

#         "organizations:DescribeAccount",

#         "organizations:ListAccounts",

#         "sts:AssumeRole",

#         "sts:GetCallerIdentity",

#         "iam:ListAccountAliases",

#         "ec2:DescribeInstances",

#         "ec2:DescribeRegions",

#         "lambda:GetAccountSettings",

#         "ecs:ListClusters",

#         "eks:ListClusters"

#       ],

#       "Resource": "*"

#     }

#   ]

# }

#

# Billing information is calculated as follows:

#

# * EC2 - 1 to 1  Example: 1 EC2 is equal to 1 Billable Instance

# * ECS/EKS/Fargate Clusters - 1 to 2  Example: 1 ECS/EKS/Fargate Cluster is equal to 2 Billable Instances

# * Lambda Functions - 50 to 1  Example: 50 Lambda Functions is equal to 1 Billable Instance

#

##########################################################################################


##########################################################################################

## Use of jq is required by this script.

##########################################################################################


if ! type "jq" > /dev/null; then

  echo "Error: jq not installed or not in execution path, jq is required for script execution."

  exit 1

fi


##########################################################################################

## Optionally query the AWS Organization by passing "org" as an argument.

##########################################################################################


if [ "${1}X" == "orgX" ] || [ "${2}X" == "orgX" ] || [ "${3}X" == "orgX" ]; then

   USE_AWS_ORG="true"

else

   USE_AWS_ORG="false"

fi


##########################################################################################

## Utility functions.

##########################################################################################


error_and_exit() {

  echo

  echo "ERROR: ${1}"

  echo

  exit 1

}


##########################################################################################

## AWS Utility functions.

##########################################################################################


#### Organization Based Utilities


aws_organizations_describe_organization() {

  RESULT=$(aws organizations describe-organization --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


aws_organizations_list_accounts() {

  RESULT=$(aws organizations list-accounts --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


aws_sts_assume_role() {

  RESULT=$(aws sts assume-role --role-arn="${1}" --role-session-name=pcs-sizing-script --duration-seconds=999 --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


get_account_list() {

  if [ "${USE_AWS_ORG}" = "true" ]; then

    echo "###################################################################################"

    echo "Querying AWS Organization"

    MASTER_ACCOUNT_ID=$(aws_organizations_describe_organization | jq -r '.Organization.MasterAccountId' 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "${MASTER_ACCOUNT_ID}" ]; then

      error_and_exit "Error: 001 Failed to describe AWS Organization, check aws cli setup, and access to the AWS Organizations API."

    fi


    TARGET_ORG_ID=''

    TARGET_ORG_ACCOUNT_NUMBER=''

    TARGET_ORG_ID=$(aws_organizations_describe_organization | jq '.Organization.Id' 2>/dev/null)

    TARGET_ORG_ACCOUNT_NUMBER=$(aws_organizations_describe_organization | jq '.Organization.MasterAccountId' 2>/dev/null)


    echo "###################################################################################"

    echo "Performing AWS Organization InsightCloudSec Billing Instance Count Analysis"

    echo "  AWS Organization ID: ${TARGET_ORG_ID}"

    echo "  AWS Organization Master Account Number: ${TARGET_ORG_ACCOUNT_NUMBER}"

    echo "###################################################################################"

    echo ""

    # Save current environment variables of the master account.

    MASTER_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID

    MASTER_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY

    MASTER_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

    #

    ACCOUNT_LIST=$(aws_organizations_list_accounts)

    if [ $? -ne 0 ] || [ -z "${ACCOUNT_LIST}" ]; then

      error_and_exit "Error: 002 Failed to list AWS Organization accounts, check aws cli setup, and access to the AWS Organizations API."

    fi

    TOTAL_ACCOUNTS=$(echo "${ACCOUNT_LIST}" | jq '.Accounts | length' 2>/dev/null)

    echo "  Total number of member accounts: ${TOTAL_ACCOUNTS}"

    echo "###################################################################################"

    echo ""

  else

    MASTER_ACCOUNT_ID=""

    ACCOUNT_LIST=""

    TOTAL_ACCOUNTS=1

  fi

}


assume_role() {

  ACCOUNT_NAME="${1}"

  ACCOUNT_ID="${2}"

  echo "###################################################################################"

  echo "Processing Account: ${ACCOUNT_NAME} (${ACCOUNT_ID})"

  if [ "${ACCOUNT_ID}" = "${MASTER_ACCOUNT_ID}" ]; then

    echo "  Account is the master account, skipping assume role ..."

  else

    ACCOUNT_ASSUME_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/OrganizationAccountAccessRole"

    SESSION_JSON=$(aws_sts_assume_role "${ACCOUNT_ASSUME_ROLE_ARN}")

    if [ $? -ne 0 ] || [ -z "${SESSION_JSON}" ]; then

      ASSUME_ROLE_ERROR="true"

      echo "  Warning: Failed to assume role into Member Account ${ACCOUNT_NAME} (${ACCOUNT_ID}), skipping ..."

    else

      # Export environment variables used to connect to this member account.

      AWS_ACCESS_KEY_ID=$(echo "${SESSION_JSON}"     | jq .Credentials.AccessKeyId     2>/dev/null | sed -e 's/^"//' -e 's/"$//')

      AWS_SECRET_ACCESS_KEY=$(echo "${SESSION_JSON}" | jq .Credentials.SecretAccessKey 2>/dev/null | sed -e 's/^"//' -e 's/"$//')

      AWS_SESSION_TOKEN=$(echo "${SESSION_JSON}"     | jq .Credentials.SessionToken    2>/dev/null | sed -e 's/^"//' -e 's/"$//')

      export AWS_ACCESS_KEY_ID

      export AWS_SECRET_ACCESS_KEY

      export AWS_SESSION_TOKEN

    fi

  fi

  echo "###################################################################################"

  echo ""

}


#### Account Based Utilities


aws_identify_account_number() {

  RESULT=$(aws sts get-caller-identity --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


aws_identify_account_alias() {

  RESULT=$(aws iam list-account-aliases --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


aws_ec2_describe_regions() {

  RESULT=$(aws ec2 describe-regions --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  fi

}


get_region_list() {


  TARGET_ACCOUNT_NUMBER=''

  TARGET_ACCOUNT_ALIAS=''

  TARGET_ACCOUNT_NUMBER=$(aws_identify_account_number | jq '.Account' 2>/dev/null)

  TARGET_ACCOUNT_ALIAS=$(aws_identify_account_alias | jq '.AccountAliases[]' 2>/dev/null)


  echo ""

  echo "###################################################################################"

  echo "Performing InsightCloudSec Billing Instance Count Analysis"

  echo "  AWS Account Number: ${TARGET_ACCOUNT_NUMBER}"

  echo "  Account Alias: ${TARGET_ACCOUNT_ALIAS}"

  echo "###################################################################################"

  echo ""

  echo "###################################################################################"

  echo "Querying AWS Regions"


  REGIONS=$(aws_ec2_describe_regions | jq -r '.Regions[] | .RegionName' 2>/dev/null | sort)


  XIFS=$IFS

  IFS=$'\n' REGION_LIST=($REGIONS)

  IFS=$XIFS


  if [ ${#REGION_LIST[@]} -eq 0 ]; then

    echo "  Warning: Using default region list"

    REGION_LIST=(us-east-1 us-east-2 us-west-1 us-west-2 ap-south-1 ap-northeast-1 ap-northeast-2 ap-southeast-1 ap-southeast-2 eu-north-1 eu-central-1 eu-west-1 sa-east-1 eu-west-2 eu-west-3 ca-central-1)

  fi


  echo "  Total number of regions: ${#REGION_LIST[@]}"

  echo "###################################################################################"

  echo ""

}


#### Asset Based Utilities for EC2, EKS, ECS, Lambda


aws_ec2_describe_instances() {

  RESULT=$(aws ec2 describe-instances --max-items 99999 --region="${1}" --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  else

    echo '{"Error": [] }'

  fi

}


aws_lambda_get_account_settings() {

  RESULT=$(aws lambda get-account-settings --region="${1}" --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  else

    echo '{"Error": [] }'

  fi

}


aws_eks_list_clusters() {

  RESULT=$(aws eks list-clusters --max-items 99999 --region="${1}" --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  else

    echo '{"Error": [] }'

  fi

}


aws_ecs_list_clusters() {

  RESULT=$(aws ecs list-clusters --max-items 99999 --region="${1}" --output json 2>/dev/null)

  if [ $? -eq 0 ]; then

    echo "${RESULT}"

  else

    echo '{"Error": [] }'

  fi

}


##########################################################################################

# Unset environment variables used to assume role into the last member account.

##########################################################################################


unassume_role() {

  AWS_ACCESS_KEY_ID=$MASTER_AWS_ACCESS_KEY_ID

  AWS_SECRET_ACCESS_KEY=$MASTER_AWS_SECRET_ACCESS_KEY

  AWS_SESSION_TOKEN=$MASTER_AWS_SESSION_TOKEN

}


##########################################################################################

## Set or reset counters.

##########################################################################################


reset_account_counters() {

  EC2_INSTANCE_COUNT=0

  LAMBDA_FUNCTION_COUNT=0

  EKS_CLUSTER_COUNT=0

  ECS_CLUSTER_COUNT=0

}


reset_global_counters() {

  EC2_INSTANCE_COUNT_GLOBAL=0

  LAMBDA_FUNCTION_COUNT_GLOBAL=0

  EKS_CLUSTER_COUNT_GLOBAL=0

  ECS_CLUSTER_COUNT_GLOBAL=0

  TOTAL_CLUSTER_GLOBAL=0

  EC2_BILLABLE_INSTANCE_GLOBAL=0

  LAMBDA_BILLABLE_INSTANCE_GLOBAL=0

  EKS_BILLABLE_INSTANCE_GLOBAL=0

  ECS_BILLABLE_INSTANCE_GLOBAL=0

  TOTAL_CLUSTER_BILLABLE_INSTANCE_GLOBAL=0

  TOTAL_BILLABLE_INSTANCE_GLOBAL=0

}


##########################################################################################

## Iterate through the (or each member) account, region, and billable resource type.

##########################################################################################


count_account_resources() {

  for ((ACCOUNT_INDEX=0; ACCOUNT_INDEX<=(TOTAL_ACCOUNTS-1); ACCOUNT_INDEX++))

  do

    if [ "${USE_AWS_ORG}" = "true" ]; then

      ACCOUNT_NAME=$(echo "${ACCOUNT_LIST}" | jq -r .Accounts["${ACCOUNT_INDEX}"].Name 2>/dev/null)

      ACCOUNT_ID=$(echo "${ACCOUNT_LIST}"   | jq -r .Accounts["${ACCOUNT_INDEX}"].Id   2>/dev/null)

      ASSUME_ROLE_ERROR=""

      assume_role "${ACCOUNT_NAME}" "${ACCOUNT_ID}"

      if [ -n "${ASSUME_ROLE_ERROR}" ]; then

        continue

      fi

    fi


    echo "###################################################################################"

    echo "EC2 Instances"

    for i in "${REGION_LIST[@]}"

    do

      RESOURCE_COUNT=$(aws_ec2_describe_instances "${i}" | jq '[ .Reservations[].Instances[] ] | length' 2>/dev/null)

      echo "  Count of EC2 Instances in Region ${i}: ${RESOURCE_COUNT}"

      EC2_INSTANCE_COUNT=$((EC2_INSTANCE_COUNT + RESOURCE_COUNT))

    done

    echo "Total EC2 Instances across all regions: ${EC2_INSTANCE_COUNT}"

    echo "###################################################################################"

    echo ""


    echo "###################################################################################"

    echo "Lambda Functions"

    for i in "${REGION_LIST[@]}"

    do

      RESOURCE_COUNT=$(aws_lambda_get_account_settings "${i}" | jq '.AccountUsage.FunctionCount' 2>/dev/null)

      echo " Count of Lambda Functions in Region ${i}: ${RESOURCE_COUNT}"

      LAMBDA_FUNCTION_COUNT=$((LAMBDA_FUNCTION_COUNT + RESOURCE_COUNT))

    done

    echo "Total Lambda Functions across all regions: ${LAMBDA_FUNCTION_COUNT}"

    echo "###################################################################################"

    echo ""


    echo "###################################################################################"

    echo "EKS Clusters"

    for i in "${REGION_LIST[@]}"

    do

      RESOURCE_COUNT=$(aws_eks_list_clusters "${i}" | jq '[ .clusters[] ] | length' 2>/dev/null)

      echo "  Count of EKS Clusters in Region ${i}: ${RESOURCE_COUNT}"

      EKS_CLUSTER_COUNT=$((EKS_CLUSTER_COUNT + RESOURCE_COUNT))

    done

    echo "Total Maximum EKS Clusters across all regions: ${EKS_CLUSTER_COUNT}"

    echo "###################################################################################"

    echo ""


    echo "###################################################################################"

    echo "ECS Clusters"

    for i in "${REGION_LIST[@]}"

    do

      RESOURCE_COUNT=$(aws_ecs_list_clusters "${i}" | jq '[ .clusterArns[] ] | length' 2>/dev/null)

      echo "  Count of ECS Clusters in Region ${i}: ${RESOURCE_COUNT}"

      ECS_CLUSTER_COUNT=$((ECS_CLUSTER_COUNT + RESOURCE_COUNT))

    done

    echo "Total Maximum ECS Clusters across all regions: ${ECS_CLUSTER_COUNT}"

    echo "###################################################################################"

    echo ""


    EC2_INSTANCE_COUNT_GLOBAL=$((EC2_INSTANCE_COUNT_GLOBAL + EC2_INSTANCE_COUNT))

    LAMBDA_FUNCTION_COUNT_GLOBAL=$((LAMBDA_FUNCTION_COUNT_GLOBAL + LAMBDA_FUNCTION_COUNT))

    EKS_CLUSTER_COUNT_GLOBAL=$((EKS_CLUSTER_COUNT_GLOBAL + EKS_CLUSTER_COUNT))

    ECS_CLUSTER_COUNT_GLOBAL=$((ECS_CLUSTER_COUNT_GLOBAL + ECS_CLUSTER_COUNT))

    TOTAL_CLUSTER_GLOBAL=$((ECS_CLUSTER_COUNT_GLOBAL + EKS_CLUSTER_COUNT_GLOBAL))


    reset_account_counters


    if [ "${USE_AWS_ORG}" = "true" ]; then

      unassume_role

    fi

  done


  EC2_BILLABLE_INSTANCE_GLOBAL=$((EC2_INSTANCE_COUNT_GLOBAL))

  LAMBDA_BILLABLE_INSTANCE_GLOBAL=$((LAMBDA_FUNCTION_COUNT_GLOBAL / 50))

  EKS_BILLABLE_INSTANCE_GLOBAL=$((EKS_CLUSTER_COUNT_GLOBAL * 2))

  ECS_BILLABLE_INSTANCE_GLOBAL=$((ECS_CLUSTER_COUNT_GLOBAL * 2))

  TOTAL_CLUSTER_BILLABLE_INSTANCE_GLOBAL=$((EKS_BILLABLE_INSTANCE_GLOBAL + ECS_BILLABLE_INSTANCE_GLOBAL))

  TOTAL_BILLABLE_INSTANCE_GLOBAL=$((EC2_BILLABLE_INSTANCE_GLOBAL + LAMBDA_BILLABLE_INSTANCE_GLOBAL + EKS_BILLABLE_INSTANCE_GLOBAL + ECS_BILLABLE_INSTANCE_GLOBAL))


  echo "###################################################################################"

  echo "InsightCloudSec: AWS Billable Resources Summary:"

  echo "  Count of EC2 Instances:     ${EC2_INSTANCE_COUNT_GLOBAL} Billable Instances: ${EC2_BILLABLE_INSTANCE_GLOBAL}"

  echo "  Count of ECS/EKS Clusters:  ${TOTAL_CLUSTER_GLOBAL} Billable Instances: ${TOTAL_CLUSTER_BILLABLE_INSTANCE_GLOBAL}"

  echo "  Count of Lambda Functions:  ${LAMBDA_FUNCTION_COUNT_GLOBAL} Billable Instances: ${LAMBDA_BILLABLE_INSTANCE_GLOBAL}"

  echo ""

  echo "InsightCloudSec: Total Billable Instances: ${TOTAL_BILLABLE_INSTANCE_GLOBAL}"

  echo "###################################################################################"


  echo ""

  echo "Totals are based upon resource counts at the time that this script is executed."

  echo "If you have any questions, please contact your Rapid7 Account Executive or Customer Support Manager."

}


##########################################################################################

# Main.

##########################################################################################


get_account_list

get_region_list

reset_account_counters

reset_global_counters

count_account_resources


