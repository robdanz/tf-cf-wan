variable "cloudflare_api_token" {
  description = "Cloudflare API token with Magic WAN Write + Account Settings Read permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "cloudflare_conduit_id" {
  description = "Cloudflare conduit ID used in the IPsec IKE FQDN identifier (<tunnel-id>.<conduit-id>.ipsec.cloudflare.com)"
  type        = string
}

variable "anycast_ip_1" {
  description = "First Cloudflare Anycast IP for IPsec tunnels (primary)"
  type        = string
}

variable "anycast_ip_2" {
  description = "Second Cloudflare Anycast IP for IPsec tunnels (secondary)"
  type        = string
}

variable "tunnel_supernet" {
  description = "Supernet for /31 inside tunnel address allocation"
  type        = string
}

variable "sites_csv_path" {
  description = "Path to the sites CSV input file"
  type        = string
  default     = "sites.csv"
}

variable "psk_length" {
  description = "Length of the generated pre-shared key"
  type        = number
  default     = 48
}

variable "health_check_enabled" {
  description = "Enable tunnel health checks"
  type        = bool
  default     = true
}

variable "health_check_type" {
  description = "Health check type: reply (ICMP reply) or request (ICMP echo request)"
  type        = string
  default     = "request"

  validation {
    condition     = contains(["reply", "request"], var.health_check_type)
    error_message = "health_check_type must be 'reply' or 'request'."
  }
}

variable "health_check_direction" {
  description = "Health check direction: unidirectional or bidirectional"
  type        = string
  default     = "bidirectional"

  validation {
    condition     = contains(["unidirectional", "bidirectional"], var.health_check_direction)
    error_message = "health_check_direction must be 'unidirectional' or 'bidirectional'."
  }
}

variable "health_check_rate" {
  description = "Health check probe rate: low, mid, or high"
  type        = string
  default     = "mid"

  validation {
    condition     = contains(["low", "mid", "high"], var.health_check_rate)
    error_message = "health_check_rate must be 'low', 'mid', or 'high'."
  }
}

variable "replay_protection" {
  description = "Enable IPsec anti-replay protection (disable unless your CPE requires it)"
  type        = bool
  default     = false
}
