-- Hipótese 08: total de pedidos por status pré-calculado para GET /pedidos?status=&pagina=
-- O count(*) de 'pago' percorre ~300 mil linhas a cada chamada. A visão guarda as 4 contagens.
-- Evidência em diagnostico/19.

\echo 'Criando visao materializada contagem_pedidos_status...'

CREATE MATERIALIZED VIEW contagem_pedidos_status AS
SELECT status, count(*) AS total
  FROM pedidos
 GROUP BY status;

-- Índice único: busca por status e permite REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX contagem_pedidos_status_status_idx ON contagem_pedidos_status (status);

ANALYZE contagem_pedidos_status;
