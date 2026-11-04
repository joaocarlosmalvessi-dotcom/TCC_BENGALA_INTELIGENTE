# Histórico de emergências

No projeto Supabase usado pelo aplicativo, abra **SQL Editor**, cole e execute
`migrations/202611010001_notificacoes_emergencia.sql`. Depois abra a nova versão
do aplicativo. A migração é transacional e pode ser reaplicada.

Ela requer as tabelas existentes `dispositivos` (ID UUID, `grupo_id`,
`emergencias`) e `membros_grupo` (`grupo_id`, `user_id`). Não altera as regras de
acesso dessas tabelas. Os membros precisam conseguir consultar o próprio grupo
e os dispositivos, como já ocorre no aplicativo.

- Na sincronização offline, o horário é o da coleta no celular, preservado até o
  envio. O protocolo atual do ESP32 não fornece o instante original do acionamento.
- O responsável é o usuário autenticado que recebeu o sinal por Bluetooth e o
  enviou. Isso não identifica automaticamente quem está carregando a bengala.
- O nome é preservado como estava no registro, com e-mail como alternativa.
- Cada sequência de sinal `1` é registrada uma vez até chegar um `0`. A fila local
  preserva esse estado ao reiniciar o app. Retentativas usam a mesma chave e não
  incrementam o total novamente. Sem um identificador no firmware, a mesma
  ocorrência recebida em aparelhos diferentes ainda pode ser considerada nova.
- Limpar remove o aviso da lista compartilhada do grupo e registra quem limpou.
  O histórico e o total `dispositivos.emergencias` são preservados para relatórios.
- A lista exibe até 100 registros. Limpar a lista limpa somente os IDs exibidos;
  alertas novos não são apagados e os anteriores são carregados depois.
- Contagens antigas viram avisos agrupados, sem horário ou autor inventados.

## Verificação no projeto

1. Entre com dois membros do mesmo grupo e um usuário de outro grupo.
2. Acione a bengala: ambos os membros devem ver um aviso com nome e hora.
3. Mantenha o sinal em `1`: o total deve subir somente uma vez. Envie `0` e
   depois `1` para produzir outro aviso.
4. Limpe um aviso e a lista, conferindo o outro membro e o total do relatório.
5. Gere um aviso enquanto o diálogo de limpeza está aberto: ele deve permanecer.
6. Confirme que o usuário do outro grupo não consegue consultar nem limpar os
   avisos dessa bengala.

Esta migração precisa ser aplicada por quem tem acesso administrativo ao
Supabase. A chave pública do aplicativo não permite criar tabelas e funções.

## Testes automatizados

`flutter test --no-pub` cobre a lista, confirmação/cancelamento de limpeza,
falhas, preservação de avisos novos e retentativas dos sinais BLE.

`tests/emergencias.mjs` executa a migração em um PostgreSQL isolado usando
`@electric-sql/pglite` (testado com 0.5.14). Instale esse pacote em uma pasta de
testes e execute `node supabase/tests/emergencias.mjs <pasta-do-pacote-pglite>`.
O script valida legado, reaplicação, autoria, horário, idempotência, contadores,
limpeza compartilhada e autorização de grupos. Não acessa o Supabase real;
as políticas existentes do seu projeto precisam da verificação manual acima.
