terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # CI injects the backend config via -backend-config (see actions/_lib/lib.sh).
  backend "s3" {}
}

provider "aws" {}
