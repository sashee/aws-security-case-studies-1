provider "aws" {
}

resource "random_id" "id" {
  byte_length = 8
}

# the protected bucket and the file
resource "aws_s3_bucket" "protected_bucket" {
  force_destroy = "true"
}

resource "aws_s3_bucket_object" "secret_file" {
  key    = "secret.txt"
  source = "${path.module}/secret.txt"
  bucket = aws_s3_bucket.protected_bucket.bucket
  etag   = filemd5("${path.module}/secret.txt")
}

# user for the lambda function
resource "aws_iam_user" "lambda_user" {
  name = "lambda-${random_id.id.hex}"
	force_destroy = "true"
}

resource "aws_iam_access_key" "lambda-keys" {
  user = aws_iam_user.lambda_user.name
}

resource "aws_iam_user_policy" "lambda_permissions" {
  user = aws_iam_user.lambda_user.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetObject"
      ],
      "Effect": "Allow",
      "Resource": "${aws_s3_bucket.protected_bucket.arn}/${aws_s3_bucket_object.secret_file.id}"
    }
  ]
}
EOF
}

# the lambda code
data "archive_file" "lambda_zip_inline" {
  type        = "zip"
  output_path = "/tmp/lambda_zip_inline.zip"
  source {
    content  = <<EOF
const AWS = require("aws-sdk");
module.exports.handler = async (event, context) => {
	const accessKeyId = "${aws_iam_access_key.lambda-keys.id}";
	const secretAccessKey = "${aws_iam_access_key.lambda-keys.secret}";
	AWS.config.credentials = new AWS.Credentials(accessKeyId,secretAccessKey);

	const s3 = new AWS.S3();
	const bucket = process.env.BUCKET;
	const key = process.env.KEY;
	const contents = await s3.getObject({Bucket: bucket, Key: key}).promise();
	return contents.Body.toString().substring(0, 5);
};
EOF
    filename = "main.js"
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_lambda_function" "lambda" {
	function_name = "function-${random_id.id.hex}"
  filename         = data.archive_file.lambda_zip_inline.output_path
  source_code_hash = data.archive_file.lambda_zip_inline.output_base64sha256
	handler = "main.handler"
  runtime = "nodejs14.x"
  role          = aws_iam_role.iam_for_lambda.arn
  environment {
    variables = {
      BUCKET = aws_s3_bucket.protected_bucket.bucket
			KEY = aws_s3_bucket_object.secret_file.id
    }
  }
}

# tester user
resource "aws_iam_user" "user" {
  name = "user-${random_id.id.hex}"
	force_destroy = "true"
}

resource "aws_iam_access_key" "user-keys" {
  user = aws_iam_user.user.name
}

resource "aws_iam_user_policy" "user_permissions" {
  user = aws_iam_user.user.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "lambda:Get*",
				"lambda:List*",
				"lambda:InvokeFunction"
      ],
      "Effect": "Allow",
      "Resource": "${aws_lambda_function.lambda.arn}"
    }
  ]
}
EOF
}

output "lambda_arn" {
  value = aws_lambda_function.lambda.arn
}

output "bucket" {
  value = aws_s3_bucket.protected_bucket.bucket
}

output "secret" {
	value = aws_s3_bucket_object.secret_file.id
}

output "access_key_id" {
	value = aws_iam_access_key.user-keys.id
}
output "secret_access_key" {
	value = aws_iam_access_key.user-keys.secret
	sensitive = true
}
