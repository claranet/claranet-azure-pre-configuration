# Claranet onboarding script

The purpose of this script is to execute all necessary high privileges actions 
needed by Claranet for Azure subscriptions management.

This includes:
* Creation of a "claranet-run" service principal
* Rights assignment of this service principal to needed subscription with following rights
    * [_Reader_](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#reader) for inventory and monitoring purposes
    * [_Cost Management Reader_](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#cost-management-reader) for FinOps purposes
    * [_Log Analytics Reader_](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#log-analytics-reader) for monitoring purpose
* Optional creation of a "Claranet DevOps" user group and rights assignment on subscriptions
* FrontDoor service principal creation for FrontDoor identity management. 
  See [Related documentation](https://docs.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-configure-https-custom-domain#register-azure-front-door)

A report is generated at the end of the script and needs to be provided to Claranet **in a secure way**.

# How to use it
_TODO_