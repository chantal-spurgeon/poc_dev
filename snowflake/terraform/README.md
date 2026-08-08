Snowflake Terraform Deployment

terraform plan \
-var-file="<snowflakeaccount>/databases.tfvars" \
-var-file="<snowflakeaccount>/warehouses.tfvars" \
-var-file="<snowflakeaccount>/security.tfvars" \
-var-file="<snowflakeaccount>/integrations.tfvars" \
-var-file="<snowflakeaccount>/rbac.tfvars" \
-var-file="<snowflakeaccount>/users.tfvars"
