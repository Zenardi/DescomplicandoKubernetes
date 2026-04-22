-- TipsBank - schema inicial
-- Executado automaticamente pelo Postgres no primeiro boot
-- (o SQLAlchemy tambem cria as tabelas se nao existirem, mas deixamos aqui
-- para ser a "fonte da verdade" e gerar dados seed)

CREATE TABLE IF NOT EXISTS contas (
    id VARCHAR(64) PRIMARY KEY,
    titular VARCHAR(120) NOT NULL,
    documento VARCHAR(14) NOT NULL UNIQUE,
    senha_hash VARCHAR(255) NOT NULL DEFAULT '',
    saldo NUMERIC(15, 2) NOT NULL DEFAULT 0,
    criada_em TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_contas_documento ON contas(documento);

CREATE TABLE IF NOT EXISTS transacoes (
    id VARCHAR(64) PRIMARY KEY,
    origem_id VARCHAR(64) NOT NULL,
    destino_id VARCHAR(64) NOT NULL,
    valor NUMERIC(15, 2) NOT NULL,
    status VARCHAR(20) NOT NULL,
    criada_em TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transacoes_origem ON transacoes(origem_id);
CREATE INDEX IF NOT EXISTS idx_transacoes_destino ON transacoes(destino_id);

-- Dados seed (2 contas de exemplo, senha padrao: "giropops")
-- O hash bcrypt abaixo foi gerado com bcrypt.hashpw("giropops", gensalt(10))
INSERT INTO contas (id, titular, documento, senha_hash, saldo) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Jeferson Fernando', '12345678901',
     '$2b$10$5SvZ8xkTk5HEldopD9Vig.UAu2icE2IxskWxaPtl1PjQ0o3xNfDme', 10000.00),
    ('22222222-2222-2222-2222-222222222222', 'LinuxTips SA',      '98765432100',
     '$2b$10$5SvZ8xkTk5HEldopD9Vig.UAu2icE2IxskWxaPtl1PjQ0o3xNfDme',   500.00)
ON CONFLICT (documento) DO NOTHING;
