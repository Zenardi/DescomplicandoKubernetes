# Como usar o Laboratorio do Girus
## Instale Girus CLI
Va ate o [repositorio](https://github.com/badtuxx/girus-cli) oficial do Girus CLI e siga as instrucoes.

## Crie o Cluster
Com a linha de comando instalada, crie o cluster usando
```shell
girus create cluster
```
NOTA: É necessario ter Docker e kind previamente instalados

## Importe o laboratorio
Importe o laboratorio case-01.yaml usando 
```shell
girus create lab -f case-01.yaml
```

Depois é só acessar o Girus e procurar pelo lab Caso 1: O Deploy de Sexta-Feira e praticar!