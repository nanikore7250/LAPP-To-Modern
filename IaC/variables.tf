variable "region" {
  default = "ap-northeast-1"
}

variable "my_ip" {
  description = "Your IP (e.g. 1.2.3.4/32)"
}

variable "key_name" {
  description = "ltm-key"
}

variable "alb_certificate_arn" {
  description = "ARN of ACM certificate to use for ALB HTTPS. Leave empty to skip HTTPS listener."
  default     = ""
}