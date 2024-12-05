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
DEFAULT_SPNAME_DEPLOY="claranet-deploy"
DEFAULT_SP_PWD_DURATION_YEARS=1
DEFAULT_GROUPNAME="Claranet DevOps"
GROUP_ROLES_OPTIONS="Owner Contributor"
SP_ROLES_LIST=("Reader" "Cost Management Reader" "Log Analytics Reader")
SP_DEPLOY_ROLES_LIST=("Contributor" "User Access Administrator")

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
Two Service Principals will be created in order to give access to the Azure resources, one with read permission the other for Claranet deployment tools (optional).
This operation needs Azure Active Directory privilege for creating AAD applications.
After creating the Service Principal, you will be asked on which subscription the access should be given.

${bldora}If you input the name of an existing Service Principal, the existing one will be used instead of creating a new one.
${txtrst}

EOT

function set_az_sp_pwd_duration() {
  INPUT_SP_Y="_"
  until [[ "$INPUT_SP_Y" =~ ^[0-9]+$ ]] || [[ -z "$INPUT_SP_Y" ]]
  do
    read -r -p "Input Service Principal password expiration delay in years (Default \"$DEFAULT_SP_PWD_DURATION_YEARS\"): " INPUT_SP_Y
  done
  printf "\n"
  SP_DURATION_Y=${INPUT_SP_Y:-$DEFAULT_SP_PWD_DURATION_YEARS}
}

function create_az_sp() {
  # TODO manage fails
  set_az_sp_pwd_duration
  SP_RESULT=$(az ad sp create-for-rbac -n "$1" --years "$SP_DURATION_Y" --skip-assignment --query "join('#', [appId,password])" -o tsv)
  SP_HASH[$1"_APP_ID"]=$(echo "$SP_RESULT" | cut -f1 -d'#')
  SP_HASH[$1"_APP_SECRET"]=$(echo "$SP_RESULT" | cut -f2 -d'#')
}

function create_sp() {
  echo "Checking if Service Principal \"$CREATE_SP\" already exists"
  SP_ID=$(az ad sp list --query "[?displayName=='$CREATE_SP'].appId" --all -o tsv)
  if [ -z "$SP_ID" ]; then
    echo "Service Principal \"$CREATE_SP\" not found"
    echo "Creating Service Principal \"$CREATE_SP\""
    printf "\n"
    create_az_sp "$CREATE_SP"
    echo "${grn}Done creating Service Principal with id ${SP_HASH[$CREATE_SP"_APP_ID"]} ${txtrst}"
  else
    echo "${ora}Service Principal \"$CREATE_SP\" found with AppId \"$SP_ID\" ${txtrst}"
    printf "\n"
    SP_HASH[$CREATE_SP"_APP_ID"]="$SP_ID"
    read -n 1 -r -p "Do you want to reset the password of the current Service Principal \"$CREATE_SP\" ($SP_ID) (y/N): " RESETPWD
    if [[ "${RESETPWD,,}" = 'y' ]]; then
      printf "\n"
      echo "Resetting Service Principal \"$CREATE_SP\" password"
      create_az_sp "$CREATE_SP"
      echo "${grn}Done resetting Service Principal with id ${SP_HASH[$CREATE_SP"_APP_ID"]} ${txtrst}"
    else
      printf "\n"
      read -n 1 -r -p "Do you want to add a new password secret to the current Service Principal \"$CREATE_SP\" ($SP_ID) (y/N): " NEWPWD
      printf "\n"
      if [[ "${NEWPWD,,}" = 'y' ]]; then
        printf "\n"
        set_az_sp_pwd_duration
        SP_HASH[$CREATE_SP"_APP_SECRET"]=$(az ad sp credential reset -n "$CREATE_SP" --years "$SP_DURATION_Y" --append --credential-description "$TODAY" --query "password" -o tsv)
        echo "${grn}Done creating a new secret password for Service Principal with id $SP_ID ${txtrst}"
      else
        SP_HASH[$CREATE_SP"_APP_SECRET"]="${ora}(existing password/secret not changed) ${txtrst}"
      fi
    fi
  fi
  printf "\n"
  SP_HASH[$CREATE_SP"_APP_OBJECT_ID"]=$(az ad app show --id "${SP_HASH[$CREATE_SP"_APP_ID"]}" --query 'id' -o tsv)
  SP_HASH[$CREATE_SP"_SP_OBJECT_ID"]=$(az ad sp show --id "${SP_HASH[$CREATE_SP"_APP_ID"]}" --query 'id' -o tsv)
}

declare -A SP_HASH

# Create Claranet Tools Service Principal
INPUT_SPNAME="_"
# TODO replace with regex ?
while [[ ${#INPUT_SPNAME} -gt 0 ]] && [[ ${#INPUT_SPNAME} -lt 8 ]] || echo "$INPUT_SPNAME" | grep -i ' '
do
  read -r -p "Input name for your ${bldgrn}Reader Service Principal${txtrst} with minimum length of 8 characters without space (press Enter to use default identifier \"${DEFAULT_SPNAME}\"): " INPUT_SPNAME
done
SP_NAME=${INPUT_SPNAME:-$DEFAULT_SPNAME}
CREATE_SP=$SP_NAME
create_sp

# Create Deployment Service Principal
SP_NAME_DEPLOY=""
read -n 1 -r -p "Would you like to to create a Deployment Service Principal (for use with application or infrastructure automated deployment) ? (Y/n): " PROCEED
if [[ "$PROCEED" = '' ]] || [[ "${PROCEED,,}" = 'y' ]]
then
  INPUT_SPNAME_DEPLOY="_"
  while [[ ${#INPUT_SPNAME_DEPLOY} -gt 0 ]] && [[ ${#INPUT_SPNAME_DEPLOY} -lt 8 ]] || echo "$INPUT_SPNAME_DEPLOY" | grep -i ' '
  do
    read -r -p "Input name for your ${bldgrn}Deployment Service Principal${txtrst} with minimum length of 8 characters without space (press Enter to use default identifier \"${DEFAULT_SPNAME_DEPLOY}\"): " INPUT_SPNAME_DEPLOY
  done
  SP_NAME_DEPLOY=${INPUT_SPNAME_DEPLOY:-$DEFAULT_SPNAME_DEPLOY}
  CREATE_SP=$SP_NAME_DEPLOY
  create_sp
fi

cat <<EOT

The Reader Service Principal $SP_NAME will now be assigned the following roles on subscriptions:
$(for role in "${SP_ROLES_LIST[@]}"; do echo "  * $role"; done)
EOT

if [[ -n $SP_NAME_DEPLOY ]]
then
  cat <<EOT

The Deployment Service Principal $SP_NAME_DEPLOY will now be assigned the following roles on subscriptions:
$(for role in "${SP_DEPLOY_ROLES_LIST[@]}"; do echo "  * $role"; done)
EOT
fi

cat <<EOT

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
    echo "Rights already assigned for subscription '$SUBSCRIPTION_CHOICE'"
  else
    for role in "${SP_ROLES_LIST[@]}"
    do
      echo "Assigning '$role' right for '$SP_NAME' to subscription '$SUBSCRIPTION_CHOICE'"
      # shellcheck disable=SC2034
      SUCCESS=""
      for try in {1..10}
      do
        # We need to loop due to Azure AD propagation latency
        az role assignment create --assignee "${SP_HASH[$SP_NAME"_APP_ID"]}" --role "$role" --scope "/subscriptions/$SUBSCRIPTION_ID" > /dev/null 2>&1 && SUCCESS="Yes" && break
        echo -n "."
        sleep 3
      done
      if [[ -z $SUCCESS ]]
      then
        printf "\n"
        echo "${bldred}Failed assigning rights on subscription '$SUBSCRIPTION_CHOICE', make sure you have enough permissions on this subscription.${txtrst}"
        printf "\n"
        continue 2
      fi
      printf "\n"
    done

    if [[ -n $SP_NAME_DEPLOY ]]
    then
      for role in "${SP_DEPLOY_ROLES_LIST[@]}"
      do
        echo "Assigning '$role' right for '$SP_NAME_DEPLOY' to subscription '$SUBSCRIPTION_CHOICE'"
        # shellcheck disable=SC2034
        for try in {1..30}
        do
          # We need to loop due to Azure AD propagation latency
          az role assignment create --assignee "${SP_HASH[$SP_NAME_DEPLOY"_APP_ID"]}" --role "$role" --scope "/subscriptions/$SUBSCRIPTION_ID" > /dev/null 2>&1 && break
          echo -n "."
          sleep 3
        done
        printf "\n"
      done
    fi

    echo "Done assigning rights to subscription \"$SUBSCRIPTION_CHOICE\""
    printf "\n"
    SUBSCRIPTION_IDS="$SUBSCRIPTION_IDS$SUBSCRIPTION_ID "
  fi
done

# Ask to add Reservations Reader a the tenant Level to be able to see Shared Reservations
RESERVATIONREADER="No"
printf "\n\n"
read -n 1 -r -p "Do you want to allow the Reader Service Principal to read Shared Reservations (Recommended) ? (Y/n): " PROCEED
if [[ "$PROCEED" = '' ]] || [[ "${PROCEED,,}" = 'y' ]]
then
  printf "\n"
  echo "Assigning ${bldgrn}Reservations Reader${txtrst} role to '$SP_NAME (${SP_HASH[$SP_NAME"_APP_ID"]})'"
  STATUS=$(az role assignment create --assignee "${SP_HASH[$SP_NAME"_APP_ID"]}" --role "Reservations Reader" --scope /providers/Microsoft.Capacity > /dev/null 2>&1 || echo "Failed")
  if [[ $STATUS == "Failed" ]]
  then
    echo "${ora}Failed assigning Reservations Reader permission.${txtrst}"
    RESERVATIONREADER="Failed"
  else
    echo "Done assigning Reservations Reader at the Tenant level."
    RESERVATIONREADER="Yes"
  fi
  printf "\n"
fi

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
  GROUP_OBJECT_ID=$(az ad group create --display-name "$GROUP_NAME" --mail-nickname "$(cat /proc/sys/kernel/random/uuid)" --query id -o tsv)
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
      echo "Assigning '$GROUP_ROLE' right for group '$GROUP_NAME' on subscription '$SUB'"
      # shellcheck disable=SC2034
      for try in {1..30}
      do
        # We need to loop due to Azure AD propagation latency
        az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$GROUP_ROLE" --scope "/subscriptions/$SUB" > /dev/null 2>&1 && break
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
Tenant id:                                            $TENANT_ID
Tenant name:                                          $TENANT_NAME
Service Principal Reader Name:                        $SP_NAME
Service Principal Reader App id:                      ${SP_HASH[$SP_NAME"_APP_ID"]}
Service Principal Reader App secret:                  ${SP_HASH[$SP_NAME"_APP_SECRET"]}
Service Principal Reader App Object id:               ${SP_HASH[$SP_NAME"_APP_OBJECT_ID"]}
Service Principal Reader SP Object id:                ${SP_HASH[$SP_NAME"_SP_OBJECT_ID"]}
Service Principal Reader Passwords expiration date:   $(az ad app show --id "${SP_HASH[$SP_NAME"_APP_ID"]}" --query "passwordCredentials[].endDateTime" -o tsv | column -t |  sed -E 's/([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})Z/\1 \2 (UTC)/')
Service Principal Deploy Name:                        $SP_NAME_DEPLOY
Service Principal Deploy App id:                      ${SP_HASH[$SP_NAME_DEPLOY"_APP_ID"]:-""}
Service Principal Deploy App secret:                  ${SP_HASH[$SP_NAME_DEPLOY"_APP_SECRET"]:-""}
Service Principal Deploy App Object id:               ${SP_HASH[$SP_NAME_DEPLOY"_APP_OBJECT_ID"]:-""}
Service Principal Deploy SP Object id:                ${SP_HASH[$SP_NAME_DEPLOY"_SP_OBJECT_ID"]:-""}
Service Principal Deploy Passwords expiration date:   $(az ad app show --id "${SP_HASH[$SP_NAME_DEPLOY"_APP_ID"]}" --query "passwordCredentials[].endDateTime" -o tsv | column -t |  sed -E 's/([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})Z/\1 \2 (UTC)/' || true)
Assigned subscriptions:                               $(if [ -z "$SUBSCRIPTION_IDS" ]; then echo "${ora}(No subscription assigned)${txtrst}"; else echo "$SUBSCRIPTION_IDS" | sed "s/ /\n                   /g"; fi)
Reservation Reader Role assigned:                     $RESERVATIONREADER
Claranet AD group name:                               $GROUP_NAME
Claranet AD group object id:                          $GROUP_OBJECT_ID
Claranet AD group role:                               $GROUP_ROLE
============================================================================================================

EOT

echo "Note: the previous ${bldred}sensitive${txtrst} information has been stored in ~/${FILENAME} file."
echo "It's recommended to remove ~/${FILENAME} file after usage."
