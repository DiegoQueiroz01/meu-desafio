-- Hipótese 03: relatório de produtos mais vendidos pré-calculado.
--
-- A rota /relatorios/top-produtos somava todos os itens de pedido a cada chamada.
-- Esta visão materializada guarda o resultado dessa soma, uma linha por produto,
-- com a mesma consulta da rota, só que sem o LIMIT: assim qualquer limite de 1 a 50 funciona.
--
-- Limite: a visão é uma foto dos dados no momento em que foi criada. Numa loja com
-- pedidos novos, ela precisaria ser atualizada de tempos em tempos com
--   REFRESH MATERIALIZED VIEW CONCURRENTLY top_produtos;
-- (o CONCURRENTLY usa o índice único abaixo e não bloqueia as leituras).
-- A carga do desafio só faz leituras, então a foto não fica desatualizada durante a medição.
--
-- O número 04 evita conflito com banco/03-indices.sql da hipótese 01 quando as branches forem juntadas.

CREATE MATERIALIZED VIEW top_produtos AS
SELECT pr.id, pr.nome, pr.categoria,
       sum(i.quantidade) AS unidades,
       sum(i.quantidade * i.preco_unitario_centavos) AS receita_centavos
  FROM itens_pedido i
  JOIN pedidos p ON p.id = i.pedido_id
  JOIN produtos pr ON pr.id = i.produto_id
 WHERE p.status <> 'cancelado'
 GROUP BY pr.id, pr.nome, pr.categoria;

-- Mesma ordem da rota: o ORDER BY ... LIMIT lê só as primeiras entradas do índice.
CREATE INDEX top_produtos_receita_idx ON top_produtos (receita_centavos DESC, id);

-- Índice único exigido pelo REFRESH ... CONCURRENTLY.
CREATE UNIQUE INDEX top_produtos_id_idx ON top_produtos (id);

ANALYZE top_produtos;
