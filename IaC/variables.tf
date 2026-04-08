variable "region" {
  default = "ap-northeast-1"
}

variable "alb_certificate_arn" {
  description = "ARN of ACM certificate to use for ALB HTTPS. Leave empty to skip HTTPS listener."
  default     = ""
}