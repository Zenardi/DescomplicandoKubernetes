# O que ele faz:
- Usa Spot VMs (Barato).
- Usa COS (Otimizado/Leve).
- Usa e2-medium (Barato e suficiente para labs).
- Cria um cluster Zonal (Para garantir a isenção da taxa de administração).
- Habilita o driver de Storage CSI automaticamente (não precisa instalar add-on).

# Passo a Passo Rápido
- Crie a conta: Vá em cloud.google.com e ative os $300 grátis.
- Crie um Projeto: Anote o ID (ex: meu-lab-12345).
- Instale o gcloud CLI: No seu computador.
- Autentique: gcloud auth application-default login
- Edite o Terraform: Coloque o ID do seu projeto no arquivo acima.
- Rode: terraform init terraform apply