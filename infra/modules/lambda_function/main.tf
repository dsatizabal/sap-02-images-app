resource "aws_iam_role" "lambda" {
  name = "${var.name}-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_policy" "lambda_basic" {
  name = "${var.name}-basic"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }]
  })
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_basic.arn
}

resource "aws_iam_policy" "appconfig_read" {
  name = "${var.name}-appconfig-read"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["appconfig:StartConfigurationSession", "appconfig:GetLatestConfiguration"], Resource = "*" }]
  })
}

resource "aws_iam_role_policy_attachment" "appconfig_read" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.appconfig_read.arn
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  handler          = var.handler
  runtime          = var.runtime
  filename         = var.filename
  source_code_hash = filebase64sha256(var.filename)
  role             = aws_iam_role.lambda.arn
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment { variables = var.env }

  layers = [
    "arn:aws:lambda:us-east-1:027255383542:layer:AWS-AppConfig-Extension:207"
  ]
}
