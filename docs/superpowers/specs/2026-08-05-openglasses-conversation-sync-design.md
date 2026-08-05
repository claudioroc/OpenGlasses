# OpenGlasses → M4 Conversation Sync — Design v1

Status: APPROVED by Claudio 2026-08-05 (brainstorming session). Not yet implemented.
Date: 2026-08-05.

## Objetivo
Levar as conversas do app OpenGlasses (Meta Ray-Ban) para a memória/contexto do
Overseer, no mesmo padrão que já existe para o Even G2 (`glasses_convo_poller.py`
→ Redis `glasses:events` → `glasses_spine_selector.py` → spine node + Qdrant).

## Contexto (por que este projeto existe)
- `~/infrastructure/logs/openglasses/` (conversations.json, debug-events.log) ficou
  parado desde 2026-08-03 13:51 UTC — populado por um pull manual único, sem
  automação nenhuma por trás.
- O app já tem uma arquitetura de sync (`SyncEngine`/`OfflineQueue`/`SyncSink`,
  `OpenGlassesApp.swift:566`), mas está ligada a um `LocalSyncSink` — um stub que
  marca tudo como "entregue" sem nunca sair do telefone. A UI ("Sync now", tela
  Field Sync) parece funcional mas não transmite nada.
- Além disso, `OfflineQueue`'s `OpKind` (`logEntry`, `photoUpload`, `llmGrounding`,
  `auditExport`, `captureRecord`) é só do módulo Field Assist — `ConversationStore.swift`
  não tem nenhuma referência a essa fila, então mesmo um sink real não cobriria
  conversas sem trabalho adicional.

## Escopo
- **Dentro**: só dados de `ConversationStore` (transcrições/pares pergunta-resposta).
- **Fora**: o sistema Field Assist (`OfflineQueue`/`SyncEngine`/`LocalSyncSink`) fica
  intocado — é um sistema à parte, sem relação com o propósito de memória/contexto.
- **Dentro**: import único (backfill) do histórico já existente em
  `~/infrastructure/logs/openglasses/conversations.json` no M4.
- **Fora**: toggle de privacidade por sessão — v1 sincroniza tudo automaticamente
  (mesma política de "início explícito, nunca auto-start" da captura em si, já
  coberta noutro lugar; este projeto só transporta o que já foi capturado).

## Arquitetura

```
iPhone (OpenGlasses app)
  ConversationStore (existente, sem mudança)
    → ConversationSyncQueue (NOVO, Swift)
        durável em disco, id estável por sessão (session_id), retry com backoff
        gatilho: fim de sessão/conversa detectado (não por turno, não por timer)
        │
        ├─ tenta M4 primeiro: POST /v1/sync/conversations
        │     glasses_router_bridge.py :3459 (endpoint novo no processo existente)
        │     autentica com o bearer já aceito (mesmo accept-list de hoje)
        │     normaliza → XADD glasses:events (source=rayban-sync)
        │     → consumido sem mudança por glasses_spine_selector.py / lifelog (já existem)
        │
        ├─ se M4 não responder em 5s (configurável, mesma ordem de grandeza do timeout de rede já usado no glasses_router_bridge.py): POST pro M2 (fallback)
        │     receptor leve novo (porta irmã da Data API :9800)
        │     grava numa fila durável local (sqlite) e confirma recebimento pro telefone
        │     relay M2→M4 (novo script, mesmo padrão do sync_m2_to_m4.sh existente)
        │       → quando M4 volta, entrega os pendentes no endpoint acima
        │
        └─ se M4 e M2 os dois inalcançáveis / tentativas esgotadas:
              escreve a conversa como arquivo solto no Documents do app
              (JSON datado, ex. conversation_2026-08-05_2201.json) — última rede
              de segurança, exportável manualmente como antes.
```

## Componentes novos

| Componente | Onde | Responsabilidade |
|---|---|---|
| `ConversationSyncQueue` | iOS (Swift) | Fila durável dedicada a conversas — NÃO é a `OfflineQueue` do Field Assist. Marca "entregue" só com ACK real de M4 ou M2 (nunca antes — ver Lição abaixo). |
| `POST /v1/sync/conversations` | M4, dentro de `glasses_router_bridge.py` | Recebe payload, autentica, normaliza em pares q/a, `XADD` no stream `glasses:events` existente. |
| Receptor M2 | M2, novo script (ou rota nova na Data API :9800) | Só grava a fila local durável quando M4 não respondeu; não processa nada, só guarda e confirma. |
| Relay M2→M4 | M2, novo script (mesmo padrão do `sync_m2_to_m4.sh`) | Dreno periódico da fila local do M2, entrega no endpoint do M4 assim que ele responde de novo. |
| Backfill único | M4, script avulso (roda manual uma vez) | Lê `conversations.json` já puxado manualmente e injeta no mesmo pipeline (`XADD`), com dedup por `session_id`. |

## Fluxo de dados e tratamento de erro

**Caminho feliz:**
1. App detecta fim de sessão → monta `{session_id, pairs: [{q, a, ts}, ...], source: "rayban"}`.
2. `ConversationSyncQueue` grava localmente primeiro (durável antes de tentar rede).
3. `POST` pro M4. 200 → M4 já fez `XADD` → item local marcado `done`.
4. `glasses_spine_selector.py` (já existe, sem mudança) processa na próxima passada.

**Falhas:**
| Onde falha | Comportamento |
|---|---|
| M4 não responde (timeout/rede) | Cai pro M2 automaticamente. M2 confirma recebimento → item local vira `done` (entregue ao M2, ainda não ao M4). |
| M2 também não responde | Item fica `pending`, retry com backoff (mesmo padrão do `SyncEngine`: `maxAttempts`, não trava a fila). |
| M2 recebeu mas M4 fica fora por horas | Fila do M2 acumula; relay tenta a cada ciclo, sem perda. |
| Tentativas esgotadas (M4 e M2 inalcançáveis por tempo demais) | Escreve arquivo solto no Documents do app — visível na tela de status como "salvo localmente, não sincronizado", nunca desaparece silenciosamente. |
| Corpo malformado / auth inválida | Erro 4xx explícito, log no M4 — nunca um 200 fingindo sucesso. |

**Dedup:** `session_id` estável; tanto o `XADD` ao vivo quanto o backfill único
verificam esse id antes de gravar — reenvio (retry, ou backfill rodando por cima
de algo que já chegou ao vivo) não duplica entradas no stream.

**Visibilidade:** a tela de status mostra 3 estados reais por item — `local only`
/ `confirmed@M2` / `confirmed@M4` — não um "sincronizado" genérico. Isso é
deliberado: o defeito do `LocalSyncSink` era justamente uma UI que dizia
"sincronizado" sem checar entrega real; este design não repete isso.

## Testes

**iOS (Swift):**
- `ConversationSyncQueue` sobrevive a restart do app com itens pendentes.
- Ordem de fallback: mock M4 indisponível → tenta M2 antes do arquivo local; mock
  os dois indisponíveis → confirma que o arquivo é escrito.
- Retry/backoff não trava a fila numa tentativa ruim.
- Dedup: reenviar o mesmo `session_id` duas vezes não duplica.

**M4/M2 (Python):**
- `POST /v1/sync/conversations`: payload válido → aparece em `glasses:events` com
  o schema que `glasses_spine_selector.py` já espera (sem tocar nesse consumidor).
- Auth: token inválido → 401, nunca 200 disfarçado.
- Receptor M2 grava e confirma; relay M2→M4 dreno real quando M4 volta (M4
  propositalmente indisponível por alguns segundos no teste).
- Backfill rodado duas vezes sobre o mesmo `conversations.json` não duplica nada.

## Rollout
1. M4: endpoint novo em `glasses_router_bridge.py` + backfill único (manual, uma vez).
2. M2: receptor + relay novos (scripts pequenos, launchd novo).
3. iOS: `ConversationSyncQueue` + wiring no `ConversationStore` — build no Xcode,
   instalação manual no telefone (não é algo que a infra M4 consiga empurrar sozinha).
4. Ordem de ativação: M4 e M2 primeiro (endpoints novos e passivos, não quebram
   nada existente); iOS por último, já testando contra a infra real.

## Decisões registradas nesta sessão (não reabrir sem motivo novo)
- Objetivo: memória/contexto do Overseer (não backup/auditoria).
- Escopo: só conversas, Field Assist fora.
- Gatilho: fim de sessão, não por turno nem por timer fixo.
- Transporte: endpoint novo dentro do processo existente (:3459), não serviço separado.
- Resiliência: M4 primário, M2 fallback, arquivo local como última rede — WhatsApp
  automático foi considerado e descartado (iOS não permite um app terceiro mandar
  WhatsApp em segundo plano sem toque do usuário; a API oficial de negócios exigiria
  um número separado, fora do self-chat/ponte já existente).
- Privacidade: sem toggle extra em v1 — tudo que já é capturado sincroniza automático.
- Backlog antigo: entra um import único (backfill), não fica de fora.
