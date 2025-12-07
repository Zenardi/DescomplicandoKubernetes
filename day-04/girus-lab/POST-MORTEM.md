# Post-Mortem: O Deploy de Sexta-Feira

## Resumo do Incidente
- **Data:** Sexta-feira, 16h
- **Duração:** ~2 horas
- **Impacto:** Serviço parcialmente indisponível
- **Causa Raiz:** Dívida técnica (falta de resources e probes)

## O que aconteceu?
Uma alteração "simples" de código aumentou levemente o consumo de memória,
causando OOMKill em Pods que não tinham limites adequados nem probes
configuradas.

## Por que aconteceu?
1. **Falta de Gestão de Recursos (Day-2)**
   - Sem requests e limits, o Pod era uma bomba-relógio
   - Qualquer variação no consumo → OOMKilled

2. **Estratégia de Rollout Otimista (Day-3)**
   - RollingUpdate sem readiness probes
   - Kubernetes não sabia se o novo Pod estava pronto

3. **Ausência de Verificações de Saúde (Day-4)**
   - Sem Readiness Probe → tráfego para Pods quebrados
   - Sem Liveness Probe → Pods "zumbis" no ar

## Ações Corretivas
- [x] Adicionar resources (requests/limits) em todos os Deployments
- [x] Implementar startupProbe, livenessProbe e readinessProbe
- [ ] Implementar políticas com OPA/Kyverno para bloquear deploys sem probes
- [ ] Adicionar alarmes para OOMKill no cluster

## Lições Aprendidas
1. Recursos não são opcionais - são a BASE da estabilidade
2. Deploy seguro = estratégia + probes trabalhando juntos
3. Sua aplicação precisa "conversar" com o Kubernetes via probes
