#!/usr/bin/env bash
# Baixa o bundle de scripts/+rules/ de GET /v1/toolkit (API da Esteira de
# Segurança) — os dois diretórios NÃO vivem mais neste repositório
# público (são o "molho secreto" de verdade do produto: as regras de
# detecção e os scripts que as usam) — passam a ser buscados aqui, na
# hora, autenticado pelo MESMO token do cliente usado pelas outras
# actions (fetch-entitlements, submit-results, ...).
#
# DIFERENTE de fetch-entitlements.sh (que tem fallback pra "camada
# Básica" se a API estiver fora do ar): aqui NÃO HÁ fallback possível —
# sem o bundle, não existe scripts/regras nenhuma pra rodar. Falha o job
# com uma mensagem clara em vez de continuar silenciosamente quebrado
# (bem diferente do resto do reusable workflow, que é resiliente de
# propósito a esta mesma API estar fora do ar).
#
# Env esperado:
#   ESTEIRA_API_URL     - base da API
#   ESTEIRA_TOKEN       - token do cliente (secret)
#   ESTEIRA_TOOLKIT_REF - tag do bundle a buscar (ex. "v1")
#
# Efeito: extrai o bundle em $RUNNER_TEMP/esteira-toolkit (GitHub
# Actions define RUNNER_TEMP; fora dele cai pra /tmp) e exporta
# ESTEIRA_WORKFLOW_DIR apontando pra lá via $GITHUB_ENV — mesma
# variável que as outras actions (run-semgrep, run-checkov, ...) já
# esperavam antes, só que agora POPULADA por download em vez de já
# existir fisicamente no checkout do repositório.

set -euo pipefail

: "${ESTEIRA_API_URL:?defina ESTEIRA_API_URL}"
: "${ESTEIRA_TOKEN:?defina ESTEIRA_TOKEN}"
: "${ESTEIRA_TOOLKIT_REF:?defina ESTEIRA_TOOLKIT_REF}"

TMP_DIR="${RUNNER_TEMP:-/tmp}"
DEST="${TMP_DIR}/esteira-toolkit"
ZIP_PATH="${TMP_DIR}/esteira-toolkit.zip"
HEADERS_PATH="${TMP_DIR}/esteira-toolkit-headers.txt"
mkdir -p "$DEST"

echo "Baixando toolkit (scripts/+rules/) da tag '${ESTEIRA_TOOLKIT_REF}'..."

set +e
http_status=$(curl -sS -o "$ZIP_PATH" -D "$HEADERS_PATH" -w "%{http_code}" -m 30 \
  -H "Authorization: Bearer ${ESTEIRA_TOKEN}" \
  "${ESTEIRA_API_URL}/v1/toolkit?ref=${ESTEIRA_TOOLKIT_REF}")
curl_exit=$?
set -e

if [[ $curl_exit -ne 0 ]]; then
  echo "::error::Não foi possível conectar em ${ESTEIRA_API_URL}/v1/toolkit — o scan não pode continuar sem o toolkit." >&2
  exit 1
fi

if [[ "$http_status" != "200" ]]; then
  detail=$(python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get('detail', '(sem detalhe)'))
except Exception:
    print('(resposta sem JSON)')" "$ZIP_PATH" 2>/dev/null || echo "(resposta sem JSON)")
  echo "::error::GET /v1/toolkit?ref=${ESTEIRA_TOOLKIT_REF} devolveu HTTP ${http_status}: ${detail}" >&2
  exit 1
fi

# Header de aviso de descontinuação, se a tag tiver um prazo configurado
# — percent-encoded (header HTTP só aceita ASCII, a mensagem é texto
# livre em PT-BR com acento), decodificado aqui antes de ecoar como
# aviso destacado no resumo do job.
deprecation_raw=$(grep -i "^x-esteira-deprecation:" "$HEADERS_PATH" 2>/dev/null | sed 's/^[^:]*: *//' | tr -d '\r' || true)
if [[ -n "$deprecation_raw" ]]; then
  deprecation=$(python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$deprecation_raw")
  echo "::warning::${deprecation}"
fi

unzip -q -o "$ZIP_PATH" -d "$DEST"
echo "ESTEIRA_WORKFLOW_DIR=${DEST}" >> "$GITHUB_ENV"
echo "Toolkit pronto em ${DEST}"
