# Diagnóstico da aplicação original

Coletado em 2026-11-09 sobre o commit `c959835` (aplicação sem mudanças). Cada conclusão aponta para o arquivo com a evidência.

## Arquivos

| Arquivo | O que tem |
|---|---|
| [01-banco-ambiente.txt](01-banco-ambiente.txt) | Versão, tamanho das tabelas, índices existentes e parâmetros do PostgreSQL |
| [02 a 08-explain-*.txt](.) | `EXPLAIN (ANALYZE, BUFFERS)` da consulta de cada rota, com parâmetros no formato que o teste de carga usa |
| [09-conexoes-por-requisicao.txt](09-conexoes-por-requisicao.txt) | Tempo de cada rota sem carga e quantas conexões ao banco cada requisição abre |
| [10-explain-com-indices.txt](10-explain-com-indices.txt) | Mesmas consultas de 02 a 08 com `banco/03-indices.sql` aplicado, e o tamanho de cada índice (hipótese 01) |
| [11-conexoes-com-pool.txt](11-conexoes-com-pool.txt) | Conexões novas por requisição com o pool de conexões (hipótese 02) |
| [13-explain-top-produtos-pre-calculado.txt](13-explain-top-produtos-pre-calculado.txt) | `EXPLAIN` de `top-produtos` lendo a visão materializada, custo do refresh e tamanho (hipótese 03) |
| [14-tempo-por-rota.txt](14-tempo-por-rota.txt) | Parte do tempo de espera dos usuários virtuais em cada rota na integração 01+02+03, calculada dos `resumo-k6.json` (motivação da hipótese 04) |
| [15-pedidos-do-cliente-uma-consulta.txt](15-pedidos-do-cliente-uma-consulta.txt) | Comandos SQL por requisição de `/clientes/:id/pedidos` antes e depois da consulta única, comparação com a lógica antiga e `EXPLAIN` (hipótese 04) |
| [16-log-sem-corpo.txt](16-log-sem-corpo.txt) | Bytes de log por requisição antes e depois de tirar o corpo da resposta do log de acesso (hipótese 05) |
| [17-vendas-por-dia-soma-no-banco.txt](17-vendas-por-dia-soma-no-banco.txt) | Linhas enviadas à API, `EXPLAIN` antes e depois da soma por dia no banco e comparação com a lógica antiga (hipótese 06) |
| [18-status-indice-cobertura.txt](18-status-indice-cobertura.txt) | `EXPLAIN` da página e da contagem de `/pedidos?status=` antes e depois do índice de cobertura, tamanho do índice e comparação com a consulta antiga (hipótese 07) |
| [19-contagem-por-status-pre-calculada.txt](19-contagem-por-status-pre-calculada.txt) | `count(*)` por status contra a leitura da visão materializada, custo do refresh e conferência dos totais (hipótese 08) |
| [20-vendas-por-dia-na-integracao.txt](20-vendas-por-dia-na-integracao.txt) | `EXPLAIN` da consulta antiga e da nova de `vendas-por-dia` com os índices da hipótese 01 (integração da hipótese 06) |
| [21-status-cobertura-na-integracao.txt](21-status-cobertura-na-integracao.txt) | Página funda de `/pedidos?status=` nos 4 status com o índice da hipótese 01 e com o índice de cobertura (integração da hipótese 07) |

## O que as evidências mostram

**1. O gargalo é o banco, não a API.** Na linha de base, o banco ficou em 99,2% de CPU (limite: 1 CPU) e a API em 5,7% (limite: 0,5 CPU). Fonte: [recursos.txt](../resultados/20261104-095227-00-linha-de-base/recursos.txt).

**2. Só existem as chaves primárias.** Não há índice em `pedidos.cliente_id`, `itens_pedido.pedido_id`, `pedidos.status`, `pedidos.criado_em`, `lower(clientes.email)` nem `produtos.nome`. Fonte: [01-banco-ambiente.txt](01-banco-ambiente.txt). Por isso, as consultas por esses campos leem a tabela inteira (`Seq Scan`) nos arquivos 03 a 08.

**3. A API abre uma conexão nova para cada consulta.** [api/src/db.js](../api/src/db.js) cria um `Client`, conecta, consulta e fecha. Toda requisição abre ao menos 1 conexão. Fonte: [09-conexoes-por-requisicao.txt](09-conexoes-por-requisicao.txt).

**4. `/clientes/:id/pedidos` faz uma consulta por pedido e outra por item (N+1).** Uma requisição abriu 17 conexões. Cada busca de itens por pedido lê toda a `itens_pedido` (1,5 milhão de linhas). Fontes: [04-explain-pedidos-do-cliente.txt](04-explain-pedidos-do-cliente.txt) e [09-conexoes-por-requisicao.txt](09-conexoes-por-requisicao.txt).

**5. `/pedidos?status=` ordena ~300 mil linhas em disco.** A consulta da página usa `Sort Method: external merge`, porque não cabe no `work_mem` de 4 MB. A contagem lê a tabela toda. Fonte: [05-explain-pedidos-por-status.txt](05-explain-pedidos-por-status.txt).

**6. `/relatorios/vendas-por-dia` não consegue usar índice de data.** O filtro `criado_em::date BETWEEN` aplica uma função sobre a coluna. A consulta também traz `observacoes`, que a rota não usa, e soma em JavaScript. Fonte: [07-explain-vendas-por-dia.txt](07-explain-vendas-por-dia.txt).

**7. `/relatorios/top-produtos` agrega as 1,5 milhão de linhas a cada chamada.** Fonte: [08-explain-top-produtos.txt](08-explain-top-produtos.txt).

**8. Busca por e-mail e por nome de produto leem a tabela inteira.** `lower(email) =` e `ILIKE '%termo%'` sem índice adequado. Fontes: [03-explain-cliente-por-email.txt](03-explain-cliente-por-email.txt) e [06-explain-busca-produtos.txt](06-explain-busca-produtos.txt).

**9. A API escreve no log o corpo inteiro de cada resposta.** Fonte: [api/src/server.js](../api/src/server.js). Hoje isso não é o gargalo (a API usa pouca CPU), mas gasta CPU e disco.

## Hipóteses de causa

- As rotas pesadas (4 a 7) ocupam a única CPU do banco. Todas as outras esperam na fila, inclusive as rápidas. Sem carga, `/clientes/4242` levou 4,5 ms ([09](09-conexoes-por-requisicao.txt)). Na carga, a mediana dessa rota foi de 200 a 290 ms ([resumos da linha de base](../resultados/)).
- Abrir uma conexão por consulta soma o custo de criar um processo no PostgreSQL a cada consulta. No N+1 isso se multiplica.
- Índices certos devem tirar a maior parte da leitura de tabela inteira. Esta é uma hipótese: só a medição confirma.
