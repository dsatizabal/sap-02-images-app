output "application_name" {
  value = aws_appconfig_application.this.name
}

output "environment_name" {
  value = aws_appconfig_environment.this.name
}

output "application_id" {
  value = aws_appconfig_application.this.id
}

output "environment_id" {
  value = aws_appconfig_environment.this.environment_id
}
