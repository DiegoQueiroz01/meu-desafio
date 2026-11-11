const { Pool } = require('pg');

// Um pool de conexões compartilhado por todas as requisições: as conexões
// ficam abertas e são reaproveitadas, em vez de abrir e fechar uma por consulta.
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'loja',
  database: process.env.DB_NAME || 'loja',
  max: 10, // padrão do node-postgres
});

// Erro numa conexão ociosa (ex.: banco reiniciou) não pode derrubar a API.
pool.on('error', (erro) => {
  console.error('erro em conexao ociosa do pool', erro);
});

async function consultar(sql, parametros = []) {
  const resultado = await pool.query(sql, parametros);
  return resultado.rows;
}

module.exports = { consultar };
