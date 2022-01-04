#!/bin/bash
#
# this script is modified from https://github.com/cloudfoundry/bosh-azure-cpi-release/blob/master/docs/get-started/create-service-principal.sh
# and makes the following assumptions
#   1. Azure CLI is installed on the machine when this script is running
#   2. Current account has sufficient privileges to create AAD application and service principal
#
#   This script will return clientID, tenantID, client-secret that must be provided to Claranet on a secure way.

set -euo pipefail

# Avoid `azure-cli` traces/debug
export AZURE_CORE_ONLY_SHOW_ERRORS=true

# Terminal colors
# Colorize and add text parameters
red=$(tput setaf 1)             #  red
grn=$(tput setaf 2)             #  green
# blu=$(tput setaf 4)             #  blue
ora=$(tput setaf 3)             #  yellow/orange
# cya=$(tput setaf 6)             #  cyan
txtbld=$(tput bold)             # Bold
bldred=${txtbld}$(tput setaf 1) #  red
bldgrn=${txtbld}$(tput setaf 2) #  green
# bldblu=${txtbld}$(tput setaf 4) #  blue
bldora=${txtbld}$(tput setaf 3) #  yellow/orange
# bldcya=${txtbld}$(tput setaf 6) #  cyan
txtrst=$(tput sgr0)             # Reset

# Script main variables
TODAY=$(date -u +"%Y%m%d-%H%M%S")
DEFAULT_SPNAME="claranet-tools"
DEFAULT_SP_PWD_DURATION_YEARS=1
DEFAULT_GROUPNAME="Claranet DevOps"
FRONTDOOR_SP_ID="ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037"
GROUP_ROLES_OPTIONS="Owner Contributor"
SP_ROLES_LIST=("Reader" "Cost Management Reader" "Log Analytics Reader")

if ! type az > /dev/null
then
    echo "${bldred}Azure CLI is not installed. Please install Azure CLI by following tutorial at https://docs.microsoft.com/en-us/cli/azure/install-azure-cli${txtrst}"
    exit 1
fi

# Check if user needs to login
if ! az resource list > /dev/null 2>&1
then
    echo "${bldred}You must be logged in with Azure CLI. Try running \"az login\". More information here: https://docs.microsoft.com/en-us/cli/azure/get-started-with-azure-cli#how-to-sign-into-the-azure-cli${txtrst}"
    exit 1
fi

TENANT_NAME=$(az rest --method get --url https://graph.microsoft.com/v1.0/domains --query 'value[?isDefault].id' -o tsv)
TENANT_ID=$(az account show --query "homeTenantId" -o tsv)
PROCEED='n'
echo "Operations will be done on Azure directory ${TENANT_NAME} (${TENANT_ID})."
read -n 1 -r -p "Do you want to proceed (y/N): " PROCEED
[[ "${PROCEED,,}" = 'y' ]] || exit

printf "\n\n"
cat <<EOT
A Service Principal will be created in order to give access to the Azure resources.
This operation needs Azure Active Directory privilege for creating AAD application.
After creating the Service Principal, you will be asked on which subscription the access should be given.

${bldora}If you input the name of an existing service principal, the existing one will be used instead of creating a new one.
${txtrst}

EOT

function set_az_sp_pwd_duration() {
  INPUT_SP_Y="_"
  until [[ "$INPUT_SP_Y" =~ ^[0-9]+$ ]] || [[ -z "$INPUT_SP_Y" ]]
  do
    read -r -p "Input number of years for your Service Principal password duration (press Enter to use default value \"$DEFAULT_SP_PWD_DURATION_YEARS\")" INPUT_SP_Y
  done
  printf "\n"
  SP_DURATION_Y=${INPUT_SP_Y:-$DEFAULT_SP_PWD_DURATION_YEARS}
}

function create_az_sp() {
  # TODO manage fails
  set_az_sp_pwd_duration
  SP_RESULT=$(az ad sp create-for-rbac -n "$SP_NAME" --years "$SP_DURATION_Y" --skip-assignment --query "join('#', [appId,password])" -o tsv)
  SP_APP_ID=$(echo "$SP_RESULT" | cut -f1 -d'#')
  SP_APP_SECRET=$(echo "$SP_RESULT" | cut -f2 -d'#')
}

# Create Service Principal
INPUT_SPNAME="_"
# TODO replace with regex ?
while [[ ${#INPUT_SPNAME} -gt 0 ]] && [[ ${#INPUT_SPNAME} -lt 8 ]] || echo "$INPUT_SPNAME" | grep -i ' '
do
  read -r -p "Input name for your Service Principal with minimum length of 8 characters without space (press Enter to use default identifier \"${DEFAULT_SPNAME}\"): " INPUT_SPNAME
done
SP_NAME=${INPUT_SPNAME:-$DEFAULT_SPNAME}

printf "\n"
echo "Checking if Service Principal \"$SP_NAME\" already exists"
SP_APP_ID=$(az ad sp list --query "[?displayName=='$SP_NAME'].appId" -o tsv)
if [ -z "$SP_APP_ID" ]; then
  echo "Service Principal \"$SP_NAME\" not found"
  echo "Creating Service Principal \"$SP_NAME\""
  create_az_sp
  echo "${grn}Done creating Service Principal with id $SP_APP_ID ${txtrst}"
else
  printf "\n"
  echo "${ora}Service Principal \"$SP_NAME\" found with AppId \"$SP_APP_ID\" ${txtrst}"
  printf "\n"
  read -n 1 -r -p "Do you want to reset the password of the current Service Principal \"$SP_NAME\" ($SP_APP_ID) (y/N): " RESETPWD
  if [[ "${RESETPWD,,}" = 'y' ]]; then
    printf "\n"
    echo "Resetting Service Principal \"$SP_NAME\" password"
    create_az_sp
    echo "${grn}Done resetting Service Principal with id $SP_APP_ID ${txtrst}"
  else
    printf "\n"
    read -n 1 -r -p "Do you want to add a new password secret to the current Service Principal \"$SP_NAME\" ($SP_APP_ID) (y/N): " NEWPWD
    if [[ "${NEWPWD,,}" = 'y' ]]; then
      printf "\n"
      set_az_sp_pwd_duration
      SP_APP_SECRET=$(az ad sp credential reset -n "$SP_NAME" --years "$SP_DURATION_Y" --append --credential-description "$TODAY" --query "password" -o tsv)
      echo "${grn}Done creating a new secret password for Service Principal with id $SP_APP_ID ${txtrst}"
    else
      SP_APP_SECRET="${ora}(existing password/secret not changed) ${txtrst}"
    fi
  fi
fi

SP_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query 'objectId' -o tsv)

cat <<EOT

The Service Principal will now be assigned the following roles on subscriptions:
$(for role in "${SP_ROLES_LIST[@]}"; do echo "  * $role"; done)
Please choose one or many subscriptions you want to assign rights on in the following list.
EOT
read -s -n 1 -r -p "(Press any key to continue)"

printf "\n"

SUBSCRIPTION_IDS=''

PS3="Select a subscription: "
FINISHED_OPTION=$(echo -e "${bldgrn}Done configuring subscriptions${txtrst}")
readarray -t SUBSCRIPTION_LIST < <(az account list --query "[?homeTenantId=='$TENANT_ID'].join('', [name, ' (', id, ')'])" -o tsv)
while true
do
  printf "\n"
  select SUBSCRIPTION_CHOICE in "${SUBSCRIPTION_LIST[@]}" "$FINISHED_OPTION"
  do
    [[ -n $SUBSCRIPTION_CHOICE ]] || { echo "${red}Invalid choice. Please try again.${txtrst}" >&2; continue; }; break
  done
  SUBSCRIPTION_ID=${SUBSCRIPTION_CHOICE: -37:36}

  [[ "$SUBSCRIPTION_CHOICE" = "$FINISHED_OPTION" ]] && break

  printf "\n"
  if [[ "$SUBSCRIPTION_IDS" =~ $SUBSCRIPTION_ID ]]
  then
    echo "Rights already assigned for subscription \"$SUBSCRIPTION_CHOICE\""
  else
    echo "Assigning rights to subscription \"$SUBSCRIPTION_CHOICE\""

    for role in "${SP_ROLES_LIST[@]}"
    do
      # shellcheck disable=SC2034
      for try in {1..30}
      do
        # We need to loop due to Azure AD propagation latency
        az role assignment create --assignee "$SP_APP_ID" --role "$role" --subscription "$SUBSCRIPTION_ID" > /dev/null 2>&1 && break
        sleep 3
      done
    done
    echo "Done assigning rights to subscription \"$SUBSCRIPTION_CHOICE\""
    printf "\n"
    SUBSCRIPTION_IDS="$SUBSCRIPTION_IDS$SUBSCRIPTION_ID "
  fi
done

# Getting Azure FrontDoor Object ID from service principal ID
printf "\n\n"
echo "Fetching Azure FrontDoor service object ID"
FRONTDOOR_OBJECT_ID=$(az ad sp show --id "$FRONTDOOR_SP_ID" --query objectId -o tsv 2>/dev/null || az ad sp create --id "$FRONTDOOR_SP_ID" --query objectId -o tsv)
echo "Azure FrontDoor service object ID: $FRONTDOOR_OBJECT_ID"

# Create Claranet group
printf "\n\n"
read -n 1 -r -p "Would you like to create a group in Active Directory for Claranet users (Recommended) ? (Y/n): " PROCEED

GROUP_NAME="N/A"
GROUP_OBJECT_ID="N/A"
GROUP_ROLE="N/A"
if [[ "$PROCEED" = '' ]] || [[ "${PROCEED,,}" = 'y' ]]
then
  printf "\n"
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
  if [[ "$PROCEED" = '' ]] || [[ "${PROCEED,,}" = 'y' ]]
  then
    PS3="Choose a role: "
    echo "Which role should have this group on previously selected subscriptions ?"
    select GROUP_ROLE in $GROUP_ROLES_OPTIONS
    do
      [[ -n $GROUP_ROLE ]] || { echo "Invalid choice. Please try again." >&2; continue; }; break
    done

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

FILENAME=claranet_setup-${TODAY}.txt
# Output information
printf "\n\n"
echo "Please send all the following information ${bldred}to your Claranet contact in a secure way.${txtrst}"
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

echo "Note: the previous information has been stored in ~/${FILENAME} file."
