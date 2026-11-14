# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 04 | `/clientes/:id/pedidos` com uma consulta, sem N+1 | [Chen et al., ICSE 2014](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf) | em medição | | | | |

---

## 04 — `/clientes/:id/pedidos` com uma consulta (sem N+1)

Branch: `hipotese/pedidos-do-cliente`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudança: a rota `/clientes/:id/pedidos` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota busca os pedidos do cliente e, dentro de um laço, faz uma consulta para os itens de cada pedido e outra para o produto de cada item ([diagnostico/README.md](diagnostico/README.md), item 4). Todo cliente tem 5 pedidos e, em média, 3 itens por pedido, então uma requisição faz em média 22 comandos SQL, um depois do outro ([diagnostico/15](diagnostico/15-pedidos-do-cliente-uma-consulta.txt)). Na aplicação original, cada consulta de itens lê a `itens_pedido` inteira (44,699 ms sozinha, [diagnostico/04](diagnostico/04-explain-pedidos-do-cliente.txt)) e abre uma conexão nova. Na integração 01+02+03, com índices e pool, a rota ainda tinha a maior mediana (532.7 ms) e o maior p95 (1106.2 ms) de todas (branch `integracao`).

**Se** a rota buscar pedidos, itens e nomes de produto numa consulta só, com `JOIN`, **então** cada requisição deixa de esperar 22 idas e voltas ao banco, o banco faz menos trabalho repetido, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** sobre a aplicação original, o ganho deve aparecer principalmente porque a `itens_pedido` deixa de ser lida inteira 5 vezes por requisição (passa a ser lida uma vez). As outras rotas continuam lendo tabelas inteiras, então o banco deve seguir perto de 100% de CPU. Como nas hipóteses 02 e 03, a mudança também será medida na branch `integracao`, onde o efeito das idas e voltas deve pesar mais.

### O que mudou

Em [api/src/rotas.js](api/src/rotas.js), o laço com uma consulta por pedido e por item virou uma consulta:

```sql
SELECT p.id, p.status, p.criado_em,
       i.id AS item_id, i.produto_id, i.quantidade, i.preco_unitario_centavos,
       pr.nome AS produto_nome
  FROM pedidos p
  LEFT JOIN itens_pedido i ON i.pedido_id = p.id
  LEFT JOIN produtos pr ON pr.id = i.produto_id
 WHERE p.cliente_id = $1
 ORDER BY p.criado_em DESC, p.id DESC, i.id
```

- **Mesma ordem:** pedidos por `criado_em DESC, id DESC` e itens de cada pedido por `id`, como nas consultas antigas.
- **Mesmo cálculo:** o `total_centavos` continua sendo somado em JavaScript, item por item, como antes.
- **`LEFT JOIN`:** um pedido sem itens continuaria aparecendo, com `itens: []` e total 0, como no código original. Nos dados atuais não há pedido sem itens (diagnostico/15, parte 2).
- **404 igual:** a consulta do cliente continua antes, para devolver `cliente nao encontrado`.
- **Também deixou de trazer colunas não usadas:** a consulta antiga de pedidos trazia `observacoes` (`SELECT *`), que a resposta não usa.

### Fontes

- Chen, Shang, Jiang, Hassan, Nasser e Flora, [Detecting Performance Anti-patterns for Applications Developed using Object-Relational Mapping](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), ICSE 2014, p. 1001–1012, seção 2.2 "One-by-one Processing" (p. 1003): o anti-padrão em que a aplicação percorre uma lista e gera um `select` para cada elemento. A correção busca os elementos em lote e "reduces the number of SQL statements significantly". A seção 2.1 "Excessive Data" descreve o problema de trazer dados que a aplicação não usa.
- Ruby on Rails Guides, [Active Record Query Interface, "N + 1 Queries Problem"](https://guides.rubyonrails.org/active_record_querying.html): o exemplo de 10 livros e seus autores "executes 1 (to find 10 books) + 10 (one per each book to load the author) = 11 queries in total".

### Evidência antes de medir

[diagnostico/15-pedidos-do-cliente-uma-consulta.txt](diagnostico/15-pedidos-do-cliente-uma-consulta.txt), uma requisição por vez, sem carga:

| URL | Comandos SQL antes | Depois |
|---|---|---|
| `/clientes/4242/pedidos` | 17 | 2 |
| `/clientes/77/pedidos` | 17 | 2 |
| `/clientes/31337/pedidos` | 17 | 2 |

- **Mesma resposta:** para 300 clientes sorteados, a resposta nova é idêntica, em texto, à montada pela lógica antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".
- **Sem índices:** a consulta nova levou 200,168 ms sozinha (lê `pedidos` e `itens_pedido` inteiras uma vez). A antiga somava 19,281 ms dos pedidos e 44,699 ms por pedido, com a `itens_pedido` lida 5 vezes (diagnostico/04).

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- Nenhum serviço novo, nenhum limite alterado, nenhum índice novo.
- **Memória da API:** a resposta continua sendo montada inteira na memória, como antes; a consulta traz uma linha por item (em média 15), com os dados do pedido repetidos em cada linha.
- **Manutenção:** a montagem da resposta passou a depender da ordem do `ORDER BY` (agrupa linhas seguidas do mesmo pedido). Quem mudar a consulta precisa manter essa ordem.

### Resultado

Ainda não medido.
