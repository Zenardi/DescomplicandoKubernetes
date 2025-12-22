terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "SEU_PROJECT_ID_AQUI" # <--- Coloque o ID do seu projeto do Google aqui
  region  = "us-central1"
}

# 1. O Cluster (Control Plane)
resource "google_container_cluster" "primary" {
  name = "k8s-storage-lab"

  # Usar ZONAL (ex: us-central1-a) em vez de REGIONAL economiza e garante a isenção da taxa
  location = "us-central1-a"

  # Deletamos o pool padrao para criar um customizado com Spot
  remove_default_node_pool = true
  initial_node_count       = 1

  # Habilita o driver CSI para Storage (Persistent Volumes)
  # Isso ja vem padrao nas versoes novas, mas garante que funcione
  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }
}

# 2. Os Nodes (Onde rodam os Pods)
resource "google_container_node_pool" "primary_nodes" {
  name     = "economico-pool"
  location = "us-central1-a"
  cluster  = google_container_cluster.primary.name

  # Quantos nós voce quer? 2 é bom para testar High Availability
  node_count = 2

  node_config {
    # --- O SEGREDO DA ECONOMIA (SPOT) ---
    spot = true

    # Tipo de maquina com bom custo beneficio (2 vCPU, 4GB RAM)
    machine_type = "e2-medium"

    # O "Bottlerocket" do Google (Ja é padrao, mas deixando explicito)
    image_type = "COS_CONTAINERD"

    # Tamanho do disco do nó (30GB é suficiente para lab, padrao é 100GB!)
    disk_size_gb = 30
    disk_type    = "pd-standard" # Disco mecanico pro sistema (mais barato que SSD)

    # Permissoes para o nó acessar os servicos do Google (Storage, Logs, etc)
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# Output para conectar
output "connect_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone us-central1-a --project SEU_PROJECT_ID_AQUI"
}