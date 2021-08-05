#!/bin/sh
#
# this script is modified from https://github.com/cloudfoundry/bosh-azure-cpi-release/blob/master/docs/get-started/create-service-principal.sh
# and makes the following assumptions
#   1. Azure CLI is installed on the machine when this script is running
#   2. Current account has sufficient privileges to create AAD application and service principal
#
#   This script will return clientID, tenantID, client-secret that must be provided to Claranet on a secure way.

set -e

DEFAULT_SPNAME="claranet-tools"
DEFAULT_GROUPNAME="Claranet DevOps"

if ! type az > /dev/null
then
    echo "Azure CLI is not installed. Please install Azure CLI by following tutorial at https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check if user needs to login
if ! az resource list > /dev/null 2>&1
then
    az login
fi

TENANT_NAME=$(az ad signed-in-user show --query 'userPrincipalName' | cut -d '@' -f 2 | sed 's/\"//')
TENANT_ID=$(az account show --query "homeTenantId" -o tsv)
PROCEED='n'
echo "Operations will be done on Azure directory $TENANT_NAME ($TENANT_ID)."
read -p "Do you want to proceed (y/N): " PROCEED
[ "$PROCEED" = 'y' ] || exit

# TODO explain what will be done here, people don't always read the README :)

# Create Service Principal
echo ""
INPUT_SPNAME="_"
while [ ${#INPUT_SPNAME} -gt 0 ] && [ ${#INPUT_SPNAME} -lt 8 ] || [ "$(echo "$INPUT_SPNAME" | grep -i ' ')" ]
do
  read -p "Input name for your Service Principal with minimum length of 8 characters without space (press Enter to use default identifier $DEFAULT_SPNAME): " INPUT_SPNAME
done
SP_NAME=${INPUT_SPNAME:-$DEFAULT_SPNAME}

echo "Using $SP_NAME as Service Principal name"

echo ""
echo "Creating Service Principal"
SP_RESULT=$(az ad sp create-for-rbac -n "$SP_NAME" --skip-assignment --query 'join(`#`, [appId,password])' -o tsv)
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
read -p "(Press enter to continue)" CONTINUEKEY

az account list --query "[?homeTenantId==\`$TENANT_ID\`].join(\`\`, [name, \` (\`, id, \`)\`])" -o tsv | nl -s ") "  # FIXME space before parenthesis is missing
SUBSCRIPTION_IDS=''
SUBSCRIPTION_NUMBER=''
while [ -z "$SUBSCRIPTION_NUMBER" ] || [ "$SUBSCRIPTION_NUMBER" != 0 ]
do
  # FIXME hitting enter without any value do things
  # TODO be able to input subscription id also
  read -p "Please enter a subscription number (0 to quit): " SUBSCRIPTION_NUMBER
  [ "$SUBSCRIPTION_NUMBER" = '0' ] || [ -z "$SUBSCRIPTION_NUMBER" ] && break

  SUBSCRIPTION_ID=$(az account list --query "[?homeTenantId==\`$TENANT_ID\`]|[$((SUBSCRIPTION_NUMBER-1))].id" -o tsv)
  echo "Assigning rights to subscription $SUBSCRIPTION_ID"
  az role assignment create --assignee "$SP_APP_ID" --role "Reader" --subscription "$SUBSCRIPTION_ID"
  az role assignment create --assignee "$SP_APP_ID" --role "Cost Management Reader" --subscription "$SUBSCRIPTION_ID"
  az role assignment create --assignee "$SP_APP_ID" --role "Log Analytics Reader" --subscription "$SUBSCRIPTION_ID"
  echo "Done assigning rights to subscription $SUBSCRIPTION_ID"
  SUBSCRIPTION_IDS="$SUBSCRIPTION_IDS $SUBSCRIPTION_ID"
done

# TODO Create FrontDoor Service Principal and fetch Object Id
# Create: az ad sp create --id ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037
# Get object Id: az ad sp show --id ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037 --query objectId -o tsv
# Possible working command: FRONTDOOR_OBJECT_ID=$(az ad sp create --id ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037 --query objectId -o tsv)

# TODO Ask to create "Claranet DevOps" group and assign "Contributor" or "Owner" right for it on previously chosen subscription ids

# Output information
# TODO output all needed information and ask to send it to Claranet
# TODO Maybe save it to a local file to avoid any lost information ?
cat <<EOT
==============Created Service Principal==============
Tenant id:                      $TENANT_ID
Service Principal Name:         $SP_NAME
Service Principal App id:       $SP_APP_ID
Service Principal App secret:   $SP_APP_SECRET
Service Principal Object id:    $SP_OBJECT_ID
Assigned subscriptions:         $(echo "$SUBSCRIPTION_IDS" | sed "s/ /\n          /g")
EOT
