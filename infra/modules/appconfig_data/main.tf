resource "aws_appconfig_configuration_profile" "this" {
  application_id = var.appconfig_application_id
  name           = var.profile_name
  location_uri   = "hosted"
  type           = "AWS.Freeform"
}

resource "aws_appconfig_deployment_strategy" "all_at_once" {
  name                           = "${var.profile_name}-all-at-once"
  deployment_duration_in_minutes = 0
  growth_factor                  = 100
  replicate_to                   = "NONE"
  final_bake_time_in_minutes     = 0
}

resource "aws_appconfig_hosted_configuration_version" "this" {
  application_id           = var.appconfig_application_id
  configuration_profile_id = aws_appconfig_configuration_profile.this.configuration_profile_id
  content_type             = "application/json"
  content                  = var.config_json
  description              = "Initial version"
}

resource "aws_appconfig_deployment" "this" {
  application_id           = var.appconfig_application_id
  configuration_profile_id = aws_appconfig_configuration_profile.this.configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.this.version_number
  deployment_strategy_id   = aws_appconfig_deployment_strategy.all_at_once.id
  environment_id           = var.appconfig_environment_id
}
