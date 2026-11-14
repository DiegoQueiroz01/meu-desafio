-- Hipótese 07: índice de cobertura para GET /pedidos?status=&pagina=
-- A página pede só id, cliente_id, status e criado_em. Com cliente_id no INCLUDE, o índice tem
-- todas as colunas da consulta e o OFFSET pode pular as linhas lendo só o índice (Index Only Scan),
-- sem visitar a tabela para cada linha pulada. Evidência em diagnostico/18.

\echo 'Criando indice de cobertura por status...'

CREATE INDEX pedidos_status_criado_cobertura_idx
    ON pedidos (status, criado_em DESC, id DESC) INCLUDE (cliente_id);

-- Mesmas colunas-chave do índice pedidos_status_criado_idx da hipótese 01 (banco/03-indices.sql),
-- que fica redundante quando os dois arquivos rodam juntos. Sem a hipótese 01, não faz nada.
DROP INDEX IF EXISTS pedidos_status_criado_idx;

-- Mapa de visibilidade em dia, para o Index Only Scan não precisar visitar a tabela.
VACUUM (ANALYZE) pedidos;
