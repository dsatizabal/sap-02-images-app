provider "aws" {
  region = var.region
}

# us-east-1 provider for Lambda@Edge & CloudFront associations
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}
