variable "region" {
  type        = string
  default     = "us-east-1"
  description = "A região da AWS onde os recursos do cluster e da rede serão provisionados."
}

variable "vpc_cidr_block" {
  type        = string
  default     = "10.0.0.0/16"
  description = "O bloco CIDR principal para a VPC, definindo o intervalo de IPs da rede."
}

variable "common_tags" {
  type        = map(string)
  description = "Tags padrão a serem aplicadas em todos os recursos criados (ex: Owner, Environment) para organização e controle de custos."
  default = {
    Owner        = "ZEE8CA"
    DateToDelete = "Today"
  }
}

variable "eks_cluster_name" {
  type        = string
  default     = "linuxtips-eks"
  description = "O nome identificador do cluster EKS."
}

variable "eks_auth_mode" {
  type        = string
  default     = "API_AND_CONFIG_MAP"
  description = "O modo de autenticação do cluster. Define se o acesso é gerenciado via API (Access Entries), ConfigMap (aws-auth) ou ambos."
}

variable "eks_node_group_capacity" {
  default     = "SPOT"
  description = "O tipo de capacidade de compra das instâncias EC2 (ON_DEMAND ou SPOT) para otimização de custos."
  type        = string
}

variable "eks_ami_type" {
  type        = string
  description = "O tipo de AMI (Sistema Operacional) usado nos nós. Deve ser compatível com a arquitetura da instância (ex: BOTTLEROCKET_ARM_64 para Graviton)."
  default     = "BOTTLEROCKET_ARM_64"
}

variable "eks_instance_types" {
  type        = list(string)
  default     = ["t4g.medium"]
  description = "Lista dos tipos de instância EC2 (hardware) que compõem o Node Group."
}

variable "eks_scaling_config_desired" {
  type        = number
  default     = 1
  description = "O número desejado de nós (workers) que o grupo deve manter rodando inicialmente."
}

variable "eks_scaling_config_max" {
  type        = number
  default     = 2
  description = "O número máximo de nós que o grupo pode escalar automaticamente (Auto Scaling)."
}

variable "eks_scaling_config_min" {
  type        = number
  default     = 1
  description = "O número mínimo de nós que o grupo deve manter disponíveis."
}