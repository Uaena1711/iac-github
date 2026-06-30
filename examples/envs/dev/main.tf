# Minimal, cheap, destroyable sample resource — proves the keyless OIDC + plan/apply flow.
resource "aws_ssm_parameter" "demo" {
  name  = "/iac-github/demo/dev"
  type  = "String"
  value = "hello-dev"
}
