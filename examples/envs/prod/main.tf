# prod differs only by intent: it maps to a `prod` GitHub Environment that you configure
# with required reviewers, so apply pauses for approval.
resource "aws_ssm_parameter" "demo" {
  name  = "/iac-github/demo/prod"
  type  = "String"
  value = "hello-prod"
}
