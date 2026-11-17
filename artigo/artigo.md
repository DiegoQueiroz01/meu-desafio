# Gargalos encadeados: otimização incremental e medida de uma API Node.js com PostgreSQL

**Autor:** Diêgo Santos Queiroz · **Repositório:** branch integracao · **Data:** novembro de 2026

## 1. Resumo

Este trabalho reduz a latência e aumenta a vazão de uma API de loja (Node.js 20, Express, PostgreSQL 16, em Docker Compose) sem alterar as respostas nem os limites de CPU e memória. Oito hipóteses foram derivadas de um diagnóstico com EXPLAIN ANALYZE. Cada uma foi medida primeiro isolada, contra a linha de base, e depois integrada às anteriores, sempre pela mediana de três execuções de carga. Sete foram mantidas e uma foi refutada. A vazão passou de 4.78 para 203.17 req/s e o p95 de 14401.8 para 291.1 ms. O resultado principal é metodológico: três mudanças com ganho pequeno ou nulo isoladas tiveram ganho grande depois que o gargalo anterior foi removido.

## 2. Contexto e diagnóstico

A carga simula 20 usuários por 60 s sobre sete rotas de leitura. O banco tem 1 CPU e 512 MiB, a API, 0,5 CPU e 256 MiB. Na linha de base, o banco usou 99.8% de CPU e a API 5.8% (resultados/*-00-linha-de-base). O gargalo era, portanto, o banco.

O diagnóstico ([diagnostico/README.md](../diagnostico/README.md)) encontrou: só chaves primárias, o que forçava leitura de tabela inteira (Seq Scan) nos filtros; uma conexão nova por consulta; o anti-padrão N+1 em /clientes/:id/pedidos (17 conexões numa requisição); ordenação em disco e count(*) de 300 mil linhas em /pedidos?status=; e agregações completas a cada chamada em vendas-por-dia e top-produtos. Uma medição com pg_stat_statements mostrou que top-produtos, com só 2% das requisições, ocupava 61.2% do tempo do banco depois dos índices ([diagnostico/12](../diagnostico/12-consumo-por-consulta.txt), branch feature/diagnostico-consumo).

## 3. Estado da arte

**Índices.** O B-tree atende igualdade, intervalo e ORDER BY com LIMIT, mas acrescenta custo de escrita e de armazenamento [1]. Índices de cobertura (INCLUDE) permitem responder só com o índice [7]. Fontes de mercado reforçam que o planejador decide pelo custo e pode ignorar um índice pouco seletivo [9, 10].

**Conexões.** O PostgreSQL usa um processo por conexão, modelo que Hellerstein et al. [3] apontam como pouco atraente para muitas conexões concorrentes; o pool reaproveita conexões e evita o handshake a cada consulta [2].

**Anti-padrões de acesso.** Chen et al. [4] descrevem o processamento um a um (N+1) e a leitura de dados não usados como anti-padrões de desempenho detectáveis em código.

**Pré-cálculo.** Visões materializadas trocam atualidade por velocidade de leitura [5]; Almeida e Lifschitz [6] destacam o custo de mantê-las atualizadas. O count(*) é lento no PostgreSQL porque o MVCC exige verificar a visibilidade de cada linha [8].

## 4. Alternativas

| Alternativa | Custo | Desempenho esperado | Risco | Esforço |
|---|---|---|---|---|
| A. Mais CPU para o banco | alto e recorrente | provável, não medido | baixo | baixo |
| B. Cache na API (memória ou serviço novo) | serviço novo ou memória por instância | alto em leituras repetidas | dados velhos e invalidação | médio |
| C. Índices adequados | disco e escrita mais lenta | alto nos filtros seletivos | baixo | baixo |
| D. Reescrever consultas (N+1, soma no banco) | nenhum em infraestrutura | médio, por rota | quebrar o contrato | médio |
| E. Pré-cálculo em visões materializadas | refresh e defasagem | alto nos agregados | dados defasados | médio |
| F. Pool de conexões | nenhum | médio | fila no pool | baixo |

## 5. Solução escolhida

Foram escolhidas C, D, E e F, que atacam o custo por requisição sem aumentar recurso. A alternativa A foi descartada porque o desafio pede uma aplicação também mais barata; ela fica como teste de comparação ([proximos-testes.md](../proximos-testes.md), T7). B foi descartada porque exige invalidação e, num serviço novo, custo adicional.

O método segue três regras: uma mudança por branch; hipótese e critério de confirmação escritos antes de medir; e integração gradual. Cada hipótese é medida isolada contra a linha de base e, se mantida, integrada e medida contra a integração anterior, porque um gargalo pode esconder outro. O contrato de respostas foi verificado antes de cada medição.

## 6. Experimento e resultado

Mediana de três execuções (scripts/medir.sh, VUS=20, DURACAO=60s, SEMENTE=42). Pastas em resultados/<data>-<rótulo>/; detalhes por rota em [experimentos.md](../experimentos.md).

| Etapa (rótulo) | req/s | p95 (ms) | CPU banco | CPU API |
|---|---|---|---|---|
| Linha de base (00-linha-de-base) | 4.78 | 14401.8 | 99.8% | 5.8% |
| + 01 índices (01-indices) | 19.73 | 4102.9 | 98.7% | 15.8% |
| + 02 pool (01-02-indices-pool) | 36.47 | 2467.9 | 98.4% | 21.8% |
| + 03 top-produtos pré-calculado (01-02-03-indices-pool-top) | 98.09 | 788.6 | 84.9% | 46.7% |
| + 04 sem N+1 (01-a-04-integracao) | 101.67 | 482.8 | 83.7% | 44.1% |
| + 05 log sem corpo (01-a-05-integracao), refutada | 98.90 | 566.8 | 80.0% | 45.4% |
| + 06 soma no banco (01-a-04-06-integracao) | 110.23 | 497.8 | 99.2% | 5.6% |
| + 07 índice de cobertura (01-a-04-06-07-integracao) | 161.25 | 482.9 | 98.4% | 6.6% |
| + 08 total por status pré-calculado (01-a-04-06-a-08-integracao) | 203.17 | 291.1 | 98.4% | 8.5% |

Na configuração final, o p99 caiu de 16990.0 para 304.4 ms, com 0.00% de erros. A memória máxima do banco foi de 283.6 para 210.7 MiB e a da API de 40.5 para 29.5 MiB. Nenhum limite foi alterado.

Três resultados sustentam a tese de gargalos encadeados. Isolados, o pool levou a vazão de 4.78 para 5.51 req/s e top-produtos pré-calculado para 5.05; integrados, o pool levou de 19.73 para 36.47 req/s e o pré-cálculo, de 36.47 para 98.09. A hipótese 08, com ganho dentro da variação quando isolada, levou a integração de 161.25 para 203.17 req/s. O mesmo vale ao contrário: com a API perto do limite (44.1%), a hipótese 05 supôs que o custo era o log do corpo das respostas e foi refutada; a causa real era a soma de vendas-por-dia em JavaScript, e movê-la para o banco (06) baixou a CPU da API para 5.6% e devolveu o gargalo ao banco. A 05 foi desfeita e mantida no registro.

## 7. Limites

- **Defasagem não medida.** As visões materializadas nunca foram atualizadas durante a carga. Sem carga, o refresh de top_produtos levou 743.291 ms com CONCURRENTLY ([diagnostico/13](../diagnostico/13-explain-top-produtos-pre-calculado.txt)). Parte do ganho de 03 e 08 pode não sobreviver a um refresh periódico (teste T4).
- **Só leituras.** A carga não escreve, então o custo de escrita dos índices e das visões não foi medido.
- **Critério parcial.** Na integração, a hipótese 06 aumentou a vazão, mas o p95 subiu de 482.8 para 497.8 ms; o critério exigia as duas melhorias. Ela foi mantida por decisão do autor, registrada no experimentos.md.
- **Degraus de ~100 ms.** Na medição final, as medianas por rota ficaram perto de múltiplos de 100 ms. Uma explicação possível é o período padrão de 100 ms do controle de CPU do container [11], mas isso não foi testado (T3).
- **Ambiente único.** Uma máquina, uma semente e três execuções por etapa. As instruções do desafio alertam que a variação entre execuções pode passar de 30%; por isso, a comparação usa o resultado geral, e os resultados por rota são citados com cautela.

## 8. Referências

Tipo entre colchetes: [A] acadêmica, [P] primária (documentação oficial), [M] mercado.

1. [P] PostgreSQL Global Development Group. *PostgreSQL 16 Documentation*, cap. 11, Indexes. https://www.postgresql.org/docs/16/indexes.html
2. [P] node-postgres. *Pooling*. https://node-postgres.com/features/pooling
3. [A] Hellerstein, J. M.; Stonebraker, M.; Hamilton, J. Architecture of a Database System. *Foundations and Trends in Databases*, v. 1, n. 2, p. 141–259, 2007. DOI 10.1561/1900000002. https://courses.cs.washington.edu/courses/cse544/20wi/papers/DBArchitecture.pdf
4. [A] Chen, T.-H.; Shang, W.; Jiang, Z. M.; Hassan, A. E.; Nasser, M.; Flora, P. Detecting Performance Anti-patterns for Applications Developed using Object-Relational Mapping. *ICSE 2014*, p. 1001–1012. https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf
5. [P] PostgreSQL Global Development Group. *PostgreSQL 16 Documentation*, 41.3 Materialized Views. https://www.postgresql.org/docs/16/rules-materializedviews.html
6. [A] Almeida, A. C. B.; Lifschitz, S. (Auto) Sintonia-fina em Sistemas de Bancos de Dados nas Organizações. In: *V Escola Regional de Sistemas de Informação do RJ*. SBC, 2018. https://books-sol.sbc.org.br/index.php/sbc/catalog/download/7/12/38-1
7. [P] PostgreSQL Global Development Group. *PostgreSQL 16 Documentation*, CREATE INDEX. https://www.postgresql.org/docs/16/sql-createindex.html
8. [P] PostgreSQL Wiki. *Slow Counting*. https://wiki.postgresql.org/wiki/Slow_Counting
9. [M] Vila, V. Índices no PostgreSQL: estratégias para otimização de consultas complexas. *Alura*, 19 nov. 2024. https://www.alura.com.br/artigos/indices-no-postgresql
10. [M] johnmaicon. Achei que era só um filtro de busca. O PostgreSQL me mostrou que não. *TabNews*. https://www.tabnews.com.br/johnmaicon/um-filtro-de-busca-simples-me-ensinou-como-o-postgres-decide-nao-usar-um-indice
11. [P] Linux Kernel Documentation. *CFS Bandwidth Control*. https://docs.kernel.org/scheduler/sched-bwc.html

## 9. Uso de IA

O uso de IA se deu com o Claude Code (Anthopic) como assistente, seguindo um fluxo de tirar dúvidas, ajudar na análise de métricas, e validar ideias e suposições. Quando necessário a ferramenta propós melhorias que foram testadas e validadas pelo autor.