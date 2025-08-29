resource "aws_appconfig_application" "this" {
  name = var.name_prefix
}

resource "aws_appconfig_environment" "this" {
  application_id = aws_appconfig_application.this.id
  name           = var.env_name
}
