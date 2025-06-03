terraform {
  required_providers {
    snowflake = {
      source = "snowflakedb/snowflake"
      version = "2.1.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
  }
}

locals {
  organization_name = "SFSEHOL"
  account_name      = "SUMMIT25_DATA_PROJECTS_CI_CD_SVDPAV"
  private_key_path  = "../.snowflake/RSA_KEY.p8"
}

provider "snowflake" {
    organization_name = local.organization_name
    account_name      = local.account_name
    user              = "SERVICE_USER"
    role              = "SYSADMIN"
    authenticator     = "SNOWFLAKE_JWT"
    private_key       = file(local.private_key_path)
}

resource "snowflake_database" "tf_db" {
  name    = "TF_DEMO_DB"
  comment = "Summit demo 2025"
}

resource "snowflake_warehouse" "tf_warehouse" {
  name = "TF_DEMO_WH"
  warehouse_size = "SMALL"
}

# Create a new schema in the DB
resource "snowflake_schema" "tf_schema" {
  name                = "TF_DEMO_SC"
  database            = snowflake_database.tf_db.name
}


resource "snowflake_schema" "tf_schema2" {
  name                = "TF_DEMO_SC2"
  database            = "TF_DEMO_DB"

  depends_on = [snowflake_database.tf_db]
}

# New provider that will use USERADMIN to create users, roles, and grants
provider "snowflake" {
    organization_name = local.organization_name
    account_name      = local.account_name
    user              = "SERVICE_USER"
    role              = "USERADMIN"
    alias             = "useradmin"
    authenticator     = "SNOWFLAKE_JWT"
    private_key       = file(local.private_key_path)
}

resource "snowflake_account_role" "tf_role" {
    provider          = snowflake.useradmin
    name              = "TF_DEMO_ROLE"
    comment           = "My Terraform role"
}

# Grant the new role to SYSADMIN (best practice)
resource "snowflake_grant_account_role" "grant_tf_role_to_sysadmin" {
    provider         = snowflake.useradmin
    role_name        = snowflake_account_role.tf_role.name
    parent_role_name = "SYSADMIN"
}

# Create a key for the new user
resource "tls_private_key" "svc_key" {
    algorithm = "RSA"
    rsa_bits  = 2048
}

# some trimming to make the key's format compliant with the snowflake_user resource
locals {
  trimmed_public_key = trimspace(
    replace(
      replace(
        tls_private_key.svc_key.public_key_pem, "-----BEGIN PUBLIC KEY-----", ""
      ), "-----END PUBLIC KEY-----", ""
    )
  )
}

# Create a new user
resource "snowflake_user" "tf_user" {
    provider          = snowflake.useradmin
    name              = "TF_DEMO_USER"
    default_warehouse = snowflake_warehouse.tf_warehouse.name
    default_role      = snowflake_account_role.tf_role.name
    default_namespace = snowflake_schema.tf_schema.fully_qualified_name
    rsa_public_key    = local.trimmed_public_key
}

# Grant account role to our newly added user
resource "snowflake_grant_account_role" "grants" {
    provider          = snowflake.useradmin
    role_name         = snowflake_account_role.tf_role.name
    user_name         = snowflake_user.tf_user.name
}

# Grant usage and monitor on the database
resource "snowflake_grant_privileges_to_account_role" "grant_usage_tf_db_to_tf_role" {
    provider          = snowflake.useradmin
    privileges        = ["USAGE", "MONITOR"]
    account_role_name = snowflake_account_role.tf_role.name
    on_account_object {
        object_type = "DATABASE"
        object_name = snowflake_database.tf_db.name
  }
}

# Grant usage on the schema
resource "snowflake_grant_privileges_to_account_role" "grant_usage_tf_schema_to_tf_role" {
    provider          = snowflake.useradmin
    privileges        = ["USAGE"]
    account_role_name = snowflake_account_role.tf_role.name
    on_schema {
        schema_name = snowflake_schema.tf_schema.fully_qualified_name
  }
}

# Grant select on the future tables in the schema
resource "snowflake_grant_privileges_to_account_role" "grant_future_tables_to_tf_role" {
    provider          = snowflake.useradmin
    privileges        = ["SELECT"]
    account_role_name = snowflake_account_role.tf_role.name
    on_schema_object {
        future {
            object_type_plural = "TABLES"
            in_schema          = snowflake_schema.tf_schema.fully_qualified_name
    }
  }
}