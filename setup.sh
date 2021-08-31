#!/bin/bash
#
# this script is modified from https://github.com/cloudfoundry/bosh-azure-cpi-release/blob/master/docs/get-started/create-service-principal.sh
# and makes the following assumptions
#   1. Azure CLI is installed on the machine when this script is running
#   2. Current account has sufficient privileges to create AAD application and service principal
#
#   This script will return clientID, tenantID, client-secret that must be provided to Claranet on a secure way.

set -e

export AZURE_CORE_ONLY_SHOW_ERRORS=true

DEFAULT_SPNAME="claranet-tools"
DEFAULT_GROUPNAME="Claranet DevOps"
FRONTDOOR_SP_ID="ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037"

if ! type az > /dev/null
then
    echo "Azure CLI is not installed. Please install Azure CLI by following tutorial at https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check if user needs to login
if ! az resource list > /dev/null 2>&1
then
    echo "You must be logged in with Azure CLI. Try running \"az login\". More information here: https://docs.microsoft.com/en-us/cli/azure/get-started-with-azure-cli#how-to-sign-into-the-azure-cli"
    exit 1
fi

TENANT_NAME=$(az ad signed-in-user show --query 'userPrincipalName' | cut -d '@' -f 2 | sed 's/\"//')
TENANT_ID=$(az account show --query "homeTenantId" -o tsv)
PROCEED='n'
echo "Operations will be done on Azure directory $TENANT_NAME ($TENANT_ID)."
read -n 1 -r -p "Do you want to proceed (y/N): " PROCEED
[ "$PROCEED" = 'y' ] || exit

cat <<EOT

A Service Principal will be created in order to give access to the Azure resources.
This operation needs Azure Active Directory privilege for creating AAD application.
After creating the Service Principal, you will be asked on which subscription the access should be given.

EOT

# Create Service Principal
INPUT_SPNAME="_"
while [ ${#INPUT_SPNAME} -gt 0 ] && [ ${#INPUT_SPNAME} -lt 8 ] || echo "$INPUT_SPNAME" | grep -i ' '
do
  read -r -p "Input name for your Service Principal with minimum length of 8 characters without space (press Enter to use default identifier \"$DEFAULT_SPNAME\"): " INPUT_SPNAME
done
SP_NAME=${INPUT_SPNAME:-$DEFAULT_SPNAME}

printf "\n"
echo "Creating Service Principal \"$SP_NAME\""
# TODO manage fails
SP_RESULT=$(az ad sp create-for-rbac -n "$SP_NAME" --skip-assignment --query "join('#', [appId,password])" -o tsv)
SP_APP_ID=$(echo "$SP_RESULT" | cut -f1 -d'#')
SP_APP_SECRET=$(echo "$SP_RESULT" | cut -f2 -d'#')
SP_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query 'objectId' -o tsv)
echo "Done creating Service Principal with id $SP_APP_ID"

cat <<EOT

The Service Principal will now be assigned the following roles on subscriptions:
  * Reader
  * Cost Management Reader
  * Log Analytics Reader
Please choose one or many subscriptions you want to assign rights on in the following list.
EOT
read -s -n 1 -r -p "(Press any key to continue)"

printf "\n"
SUBSCRIPTION_LIST=$(az account list --query "[?homeTenantId=='$TENANT_ID'].join('', [name, ' (', id, ')'])" -o tsv | nl -s ") ")
echo "$SUBSCRIPTION_LIST"

SUBSCRIPTION_COUNT=$(echo "$SUBSCRIPTION_LIST" | wc -l)
SUBSCRIPTION_IDS=''

while true
do
  # TODO be able to input subscription id also
  SUBSCRIPTION_NUMBER=''
  while ! [[ "$SUBSCRIPTION_NUMBER" =~ ^[0-9]+$ ]] || [ "$SUBSCRIPTION_NUMBER" -lt 1 ] 2>/dev/null || [ "$SUBSCRIPTION_NUMBER" -gt "$SUBSCRIPTION_COUNT" ] 2>/dev/null
  do
    read -r -p "Please enter a subscription number (empty value to quit): " SUBSCRIPTION_NUMBER
  [ -z "$SUBSCRIPTION_NUMBER" ] && break 2
  done

  SUBSCRIPTION_ID=$(az account list --query "[?homeTenantId==\`$TENANT_ID\`]|[$((SUBSCRIPTION_NUMBER-1))].id" -o tsv)
  printf "\n"
  echo "Assigning rights to subscription $SUBSCRIPTION_ID"
  # shellcheck disable=SC2034
  for try in {1..30}
  do
    # We need to loop due to Azure AD propagation latency
    az role assignment create --assignee "$SP_APP_ID" --role "Reader" --subscription "$SUBSCRIPTION_ID" > /dev/null 2>&1 && break
    sleep 3
  done
  az role assignment create --assignee "$SP_APP_ID" --role "Cost Management Reader" --subscription "$SUBSCRIPTION_ID" > /dev/null
  az role assignment create --assignee "$SP_APP_ID" --role "Log Analytics Reader" --subscription "$SUBSCRIPTION_ID" > /dev/null
  echo "Done assigning rights to subscription $SUBSCRIPTION_ID"
  printf "\n"
  SUBSCRIPTION_IDS="$SUBSCRIPTION_IDS$SUBSCRIPTION_ID "
done

# Getting Azure FrontDoor Object ID from service principal ID
printf "\n\n"
echo "Fetching Azure FrontDoor service object ID"
FRONTDOOR_OBJECT_ID=$(az ad sp show --id "$FRONTDOOR_SP_ID" --query objectId -o tsv 2>/dev/null || az ad sp create --id "$FRONTDOOR_SP_ID" --query objectId -o tsv)
echo "Azure FrontDoor service object ID: $FRONTDOOR_OBJECT_ID"

# Create Claranet group
printf "\n\n"
read -n 1 -r -p "Would you like to create a group in Active Directory for Claranet users (Recommended) ? (Y/n): " PROCEED

if [ "$PROCEED" = '' ] || [ "$PROCEED" = 'y' ]
then
  read -r -p "Input name for Claranet Group (press Enter to use default name \"$DEFAULT_GROUPNAME\"): " INPUT_GROUPNAME
  GROUP_NAME=${INPUT_GROUPNAME:-$DEFAULT_GROUPNAME}
  printf "\n"
  echo "Creating Group \"$GROUP_NAME\""
  # TODO manage fails
  GROUP_OBJECT_ID=$(az ad group create --display-name "$GROUP_NAME" --mail-nickname "$(cat /proc/sys/kernel/random/uuid)" --query objectId -o tsv)
  echo "Done creating Group with id $GROUP_OBJECT_ID"
  echo "You will need to invite members in this group."

  printf "\n"
  read -n 1 -r -p "Would you like to give rights for this group on previously selected subscriptions ? (Y/n): " PROCEED
  if [ "$PROCEED" = '' ] || [ "$PROCEED" = 'y' ]
  then
    while [ "$INPUT_ROLE" != '1' ] && [ "$INPUT_ROLE" != '2' ]
    do
      read -n 1 -r -p "Which role should have this group on previously selected subscriptions ? 1) Owner 2) Contributor (Type 1 or 2): " INPUT_ROLE
      printf "\n"
    done
    [ "$INPUT_ROLE" = '1' ] && GROUP_ROLE="Owner"
    [ "$INPUT_ROLE" = '2' ] && GROUP_ROLE="Contributor"

    for SUB in $SUBSCRIPTION_IDS
    do
      printf "\n"
      echo "Assigning $GROUP_ROLE right for group $GROUP_OBJECT_ID on subscription $SUB"
      # shellcheck disable=SC2034
      for try in {1..30}
      do
        # We need to loop due to Azure AD propagation latency
        az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$GROUP_ROLE" --subscription "$SUB" > /dev/null 2>&1 && break
        sleep 3
      done
      echo "Done assigning role"
    done
  fi
fi

FILENAME=claranet_onboarding-$(date -u +"%Y%m%d-%H%M%S").txt
# Output information
echo "Please send all the following information to your Claranet contact in a secure way"
# shellcheck disable=SC2001
cat <<EOT | tee ~/"$FILENAME"

========================== Sensitive information ===========================================================
Tenant id:                      $TENANT_ID
Tenant name:                    $TENANT_NAME
Service Principal Name:         $SP_NAME
Service Principal App id:       $SP_APP_ID
Service Principal App secret:   $SP_APP_SECRET
Service Principal Object id:    $SP_OBJECT_ID
Assigned subscriptions:         $(echo "$SUBSCRIPTION_IDS" | sed "s/ /\n                                /g")
FrontDoor identity object id:   $FRONTDOOR_OBJECT_ID
Claranet AD group name:         $GROUP_NAME
Claranet AD group object id:    $GROUP_OBJECT_ID
Claranet AD group role:         $GROUP_ROLE
============================================================================================================

EOT

echo "Note: the previous information has been stored in file $FILENAME in your home folder."
