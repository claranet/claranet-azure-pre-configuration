# v1.4.0 - 2023-05-26

Changed
  * AZ-1068: Optional creation of deployment Service Principal

Fixed
  * AZ-1057: Handle subscription role assignment error
  * AZ-1004: Handle reservation reader role assignment error

# v1.3.0 - 2023-02-10

Changed
  * AZ-904: Remove FrontDoor object ID generation since Managed Identities feature is GA

# v1.2.2 - 2023-01-20

Fixed
  * Fix SP Object ID in outputs

# v1.2.1 - 2022-11-25

Added
  * Add SP Object ID in outputs

# v1.2.0 - 2022-09-23

Added
  * AZ-801: Add Reservations Reader role at the tenant level to get Shared reservations
  * AZ-842: Add a new `claranet-deploy` Service Principal for CI/CD purpose

Fixed
  * AZ-842: Fix script with latest `azure-cli` updates, improve script

# v1.1.0 - 2022-01-14

Added
  * AZ-571: Add pre-commit config hook
  * AZ-571: Check for existing Azure SP before trying to create a new one
  * AZ-571: Ask the user how long the SP password/secret is valid (in years)

Fixed
  * AZ-571: Change command to retrieve Tenant name/domain

# v1.0.1 - 2022-01-03

Changed
  * AZ-571: Improved documentation and instructions

# v1.0.0 - 2021-09-09

Added
  * AZ-549: First version
