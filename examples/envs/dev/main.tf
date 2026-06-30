# Minimal, cheap, destroyable sample resource — proves the keyless OIDC + plan/apply flow.
# NOTE: `String` is fine for this non-secret demo. For real secrets use `SecureString`
# (or Secrets Manager) — and remember plan files can capture such values in cleartext.
resource "aws_ssm_parameter" "demo" {
  name  = "/iac-github/demo/dev"
  type  = "String"
  value = "hello-dev"
}
