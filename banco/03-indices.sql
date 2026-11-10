-- Índices B-tree para as consultas que o diagnóstico mostrou lendo a tabela inteira (Seq Scan).
-- Cada índice segue o filtro e a ordenação da consulta da rota em api/src/rotas.js.
-- Evidências em diagnostico/03 a 07.

\echo 'Criando indices...'

-- GET /clientes?email=   ->  WHERE lower(email) = lower($1)
CREATE INDEX clientes_lower_email_idx ON clientes (lower(email));

-- GET /clientes/:id/pedidos  ->  WHERE cliente_id = $1 ORDER BY criado_em DESC, id DESC
CREATE INDEX pedidos_cliente_criado_idx ON pedidos (cliente_id, criado_em DESC, id DESC);

-- GET /clientes/:id/pedidos (itens de cada pedido) e JOIN dos dois relatórios  ->  pedido_id = ...
CREATE INDEX itens_pedido_pedido_idx ON itens_pedido (pedido_id);

-- GET /pedidos?status=  ->  WHERE status = $1 ORDER BY criado_em DESC, id DESC LIMIT/OFFSET, e o count(*)
CREATE INDEX pedidos_status_criado_idx ON pedidos (status, criado_em DESC, id DESC);

-- GET /relatorios/vendas-por-dia  ->  WHERE criado_em::date BETWEEN $1 AND $2
-- Índice sobre a mesma expressão da consulta, para não precisar mudar a API.
CREATE INDEX pedidos_criado_dia_idx ON pedidos ((criado_em::date));

-- Atualiza as estatísticas (o planejador só conhece a expressão criado_em::date depois do ANALYZE)
-- e o mapa de visibilidade (permite Index Only Scan no count(*)).
VACUUM (ANALYZE) clientes, pedidos, itens_pedido;
