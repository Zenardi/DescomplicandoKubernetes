provider "aws" {
  region = "us-east-1"
}

# Obtém o ID da conta atual para configurar o acesso Root
data "aws_caller_identity" "current" {}

# Obtém zonas de disponibilidade
data "aws_availability_zones" "available" {}

# ==============================================================================
# 1. NETWORKING (VPC, Private/Public Subnets, NAT GW)
# ==============================================================================

resource "aws_vpc" "k8s_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "study-eks-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.k8s_vpc.id

  tags = {
    Name = "study-eks-igw"
  }
}

# --- Subnets Públicas (Para NAT GW e Load Balancers) ---
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.k8s_vpc.cidr_block, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "study-public-${count.index}"
    "kubernetes.io/role/elb" = "1" # Tag necessária para Load Balancers públicos
  }
}

# --- Subnets Privadas (Para os Worker Nodes) ---
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.k8s_vpc.cidr_block, 8, count.index + 10) # 10.0.10.0/24, 10.0.11.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "study-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1" # Tag necessária para Load Balancers internos
  }
}

# --- NAT Gateway (Configuração "Single NAT" para economizar) ---
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # NAT fica na subnet pública

  tags = {
    Name = "study-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

# --- Route Tables ---

# Rota Pública: Sai pelo Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.k8s_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "study-public-rt" }
}

# Rota Privada: Sai pelo NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.k8s_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "study-private-rt" }
}

# Associações
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# 2. IAM ROLES
# ==============================================================================

resource "aws_iam_role" "eks_cluster_role" {
  name = "study-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_node_role" {
  name = "study-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_node_role.name
}

# Cria a entrada de acesso para IAM user
resource "aws_eks_access_entry" "creator_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}


# ==============================================================================
# 3. EKS CLUSTER & ACCESS (Onde a mágica do Root acontece)
# ==============================================================================

resource "aws_eks_cluster" "main" {
  name     = "study-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  # Importante: O método de autenticação mudou para usar API Access Entries
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    # Nodes ficam nas subnets privadas
    subnet_ids = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)

    # Endpoint Público deve ser TRUE para você acessar do seu PC de casa
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# --- Configuração de Acesso para o ROOT USER ---

resource "aws_eks_access_entry" "root_user" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "root_user_policy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.root_user.principal_arn

  # Esta política dá admin total ao Root
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Dá os poderes de Admin do Cluster para o IAM user
resource "aws_eks_access_policy_association" "creator_admin_policy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.creator_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ==============================================================================
# 4. NODE GROUP (Seguro, Barato, Privado)
# ==============================================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "study-workers-spot-arm"
  node_role_arn   = aws_iam_role.eks_node_role.arn

  # Nodes agora ficam nas subnets PRIVADAS
  subnet_ids = aws_subnet.private[*].id

  capacity_type  = "SPOT"
  ami_type       = "BOTTLEROCKET_ARM_64"
  instance_types = ["t4g.medium"]

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# ==============================================================================
# 5. OUTPUTS
# ==============================================================================

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.main.name}"
}

# ==============================================================================
# 6. EKS ADD-ONS
# Gerenciando os componentes essenciais via Terraform
# ==============================================================================

# 1. EKS Pod Identity Agent (A base para autenticação moderna)
resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = "v1.2.0-eksbuild.1" # Opcional: fixar versão ou deixar a mais recente

  # Garante que o addon assuma o controle se já existir no cluster
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# 2. Kube Proxy (Regras de rede/IPtables)
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# 3. CoreDNS (Resolução de nomes interna)
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS precisa que os nós (Compute) já existam para rodar
  depends_on = [aws_eks_node_group.main]
}

# 4. VPC CNI (Rede dos Pods) - Configuração Otimizada com Pod Identity
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Configurações avançadas do CNI podem ser passadas aqui se necessário
  configuration_values = jsonencode({
    env = {
      # Habilita prefix delegation para economizar IPs (bom para clusters pequenos)
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

# ==============================================================================
# 7. POD IDENTITY ASSOCIATION (Segurança para o CNI)
# Removemos a permissão do "Node" e damos apenas para o "Pod"
# ==============================================================================

# Role exclusiva para o CNI
resource "aws_iam_role" "vpc_cni_role" {
  name = "study-vpc-cni-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com" # Novo Principal do EKS Pod Identity
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

# Anexa a policy de rede na Role do CNI (não mais na Role do Node)
resource "aws_iam_role_policy_attachment" "cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni_role.name
}

# Associação: Diz ao EKS para usar essa Role quando o pod 'aws-node' subir
resource "aws_eks_pod_identity_association" "vpc_cni" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-node" # O Service Account padrão do CNI
  role_arn        = aws_iam_role.vpc_cni_role.arn

  depends_on = [aws_eks_addon.pod_identity]
}

# ==============================================================================
# 8. STORAGE (O que faltava!) - EBS CSI DRIVER
# ==============================================================================

# 1. Role IAM para o EBS CSI Driver
# Permite que o driver converse com a API da AWS para criar/deletar discos (EC2 Volumes)
resource "aws_iam_role" "ebs_csi_role" {
  name = "study-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com" # Integração com Pod Identity
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

# Anexa a policy gerenciada da AWS que dá permissão de Storage
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_role.name
}

# 2. Instala o Add-on no Cluster EKS
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  # Garante que a versão mais recente compatível seja instalada
  addon_version = "v1.30.0-eksbuild.1" # Ou remova para pegar a default, mas é bom fixar

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # O driver precisa dos nós rodando para ser instalado
  depends_on = [aws_eks_node_group.main]
}

# 3. Associação de Identidade (A "cola" entre o K8s e a AWS)
# Diz: "O Pod do driver EBS (ServiceAccount ebs-csi-controller-sa) pode usar a Role study-ebs-csi-role"
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi_role.arn

  depends_on = [aws_eks_addon.ebs_csi]
}


# ==============================================================================
# 9. EFS (Elastic File System) - Para o Exercicio 9 (ReadWriteMany)
# ==============================================================================

# --- 1. Security Group do EFS ---
# Permite que os nós (na VPC) falem com o EFS na porta 2049
resource "aws_security_group" "efs_sg" {
  name        = "study-efs-sg"
  description = "Permite trafego NFS para o EFS"
  vpc_id      = aws_vpc.k8s_vpc.id

  ingress {
    description = "NFS da VPC inteira"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.k8s_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 2. O File System (O Disco) ---
resource "aws_efs_file_system" "k8s_efs" {
  creation_token = "k8s-lab-efs"
  encrypted      = true

  tags = {
    Name = "k8s-lab-efs"
  }
}

# --- 3. Mount Targets (As "Pontes" de Rede) ---
# Cria uma interface de rede em CADA subnet privada onde seus nós rodam
resource "aws_efs_mount_target" "zones" {
  count           = length(aws_subnet.private) # Cria 1 para cada subnet privada
  file_system_id  = aws_efs_file_system.k8s_efs.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs_sg.id]
}

# ==============================================================================
# 10. DRIVER EFS PARA KUBERNETES (Essencial!)
# ==============================================================================

# 1. Role IAM para o EFS CSI Driver
resource "aws_iam_role" "efs_csi_role" {
  name = "study-efs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_csi_role.name
}

# 2. Instala o Add-on no Cluster
resource "aws_eks_addon" "efs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-efs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# 3. Associação de Identidade (Pod Identity)
resource "aws_eks_pod_identity_association" "efs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi_role.arn

  depends_on = [aws_eks_addon.efs_csi]
}

# --- Output para facilitar sua vida ---
output "efs_id" {
  value       = aws_efs_file_system.k8s_efs.id
  description = "Copie este ID para usar no seu StorageClass do Exercicio 9"
}

# ==============================================================================
# 10. KMS (Key Management Service) - Para o Exercicio 10 (Encryption)
# ==============================================================================

# 1. A Chave Mestra (CMK)
resource "aws_kms_key" "k8s_key" {
  description             = "Chave de criptografia para volumes Kubernetes (Lab)"
  deletion_window_in_days = 7    # Se deletar, ela some de verdade em 7 dias
  enable_key_rotation     = true # Boa pratica de seguranca

  tags = {
    Name = "k8s-lab-key"
  }
}

# 2. Um Alias (Apelido) para facilitar a leitura no Console da AWS
resource "aws_kms_alias" "k8s_key_alias" {
  name          = "alias/k8s-lab-key"
  target_key_id = aws_kms_key.k8s_key.key_id
}

# --- Output Importante ---
# Este valor é o que você vai copiar para o YAML da StorageClass
output "kms_key_arn" {
  value       = aws_kms_key.k8s_key.arn
  description = "ARN da chave KMS para usar na StorageClass (Exercicio 10)"
}