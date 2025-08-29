resource "aws_ecs_cluster" "this" { name = "${var.name_prefix}-cluster" }

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}-worker"
  retention_in_days = 7
}

resource "aws_iam_role" "exec" {
  name = "${var.name_prefix}-ecs-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_policy" "task" {
  name = "${var.name_prefix}-ecs-task-perms"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = [
        "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility", "sqs:SendMessage"
      ], Resource = [var.ingest_queue_arn, var.resize_queue_arn] },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:HeadObject", "s3:PutObject"], Resource = "${var.bucket_arn}/*" },
      { Effect = "Allow", Action = ["dynamodb:UpdateItem", "dynamodb:GetItem"], Resource = var.table_arn },
      { Effect = "Allow", Action = ["appconfig:StartConfigurationSession", "appconfig:GetLatestConfiguration"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task.arn
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-ecs-sg"
  description = "Allow all egress"
  vpc_id      = "vpc-XXX" // Conveniently setting VPC manually
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "appconfig"
      image     = "public.ecr.aws/aws-appconfig/aws-appconfig-agent:2.x"
      essential = true
      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "AWS_DEFAULT_REGION", value = var.region }
      ]
      portMappings = [{ containerPort = 2772, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-region        = var.region
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-stream-prefix = "appconfig"
        }
      }
    },
    {
      name      = "worker"
      image     = var.image
      essential = true
      environment = [
        { name = "APPCONFIG_BASE_URL", value = "http://localhost:2772" },
        { name = "APPCONFIG_APPLICATION", value = var.appconfig_app },
        { name = "APPCONFIG_ENVIRONMENT", value = var.appconfig_env },
        { name = "APPCONFIG_PROFILE", value = var.appconfig_profile },
        { name = "AWS_REGION", value = var.region }
      ]
      dependsOn = [{ containerName = "appconfig", condition = "START" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-region        = var.region
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-stream-prefix = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = ["subnet-XXX"] // Conveniently setting subnet manually
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200
}
