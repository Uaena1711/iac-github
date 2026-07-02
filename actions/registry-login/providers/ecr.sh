# iac-github :: 'ecr' registry provider  (REFERENCE plugin — not exercised in CI yet).
#
# Logs Docker in to Amazon ECR. Requires AWS credentials ALREADY present in the job — run
# actions/aws-oidc (keyless) before registry-login. Demonstrates that the provider seam is real:
# a new registry is one file, no workflow change.
#
# Env: REGISTRY = <acct>.dkr.ecr.<region>.amazonaws.com  (required)
#      AWS_REGION (optional; empty = inherit ambient AWS_REGION)

provider_check() {
  command -v aws    >/dev/null 2>&1 || { echo "[ecr] aws cli not found on runner" >&2; return 1; }
  command -v docker >/dev/null 2>&1 || { echo "[ecr] docker not found on runner" >&2; return 1; }
  [ -n "${REGISTRY:-}" ] || { echo "[ecr] REGISTRY (<acct>.dkr.ecr.<region>.amazonaws.com) required" >&2; return 1; }
}

provider_login() {
  # ${VAR:+--region "$VAR"} => pass --region only when AWS_REGION is non-empty.
  # shellcheck disable=SC2086
  aws ecr get-login-password ${AWS_REGION:+--region "$AWS_REGION"} \
    | docker login "$REGISTRY" -u AWS --password-stdin
}
