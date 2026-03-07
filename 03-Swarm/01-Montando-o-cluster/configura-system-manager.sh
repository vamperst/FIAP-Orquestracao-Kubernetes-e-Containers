#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${REGION:-us-east-1}"
LOG_GROUP="${LOG_GROUP:-/ssm/ssh}"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
DOCUMENT_NAME="${DOCUMENT_NAME:-SSM-SessionManagerRunShell}"
TMP_JSON="$(mktemp /tmp/session-manager-doc.XXXXXX.json)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  echo "ERRO: falha na linha ${line_no} (exit code: ${exit_code})" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERRO: comando obrigatório não encontrado: $1" >&2
    exit 1
  }
}

require_cmd aws

echo "Validando credenciais AWS..."
aws sts get-caller-identity --region "$REGION" >/dev/null

echo "Montando documento temporário..."
cat > "$TMP_JSON" <<EOF
{
  "schemaVersion": "1.0",
  "description": "Document to hold regional settings for Session Manager",
  "sessionType": "Standard_Stream",
  "inputs": {
    "cloudWatchLogGroupName": "${LOG_GROUP}",
    "cloudWatchEncryptionEnabled": false,
    "cloudWatchStreamingEnabled": false,
    "shellProfile": {
      "linux": "bash\\nsudo su -"
    }
  }
}
EOF

echo "Verificando/creando CloudWatch Log Group: ${LOG_GROUP}"
if aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --region "$REGION" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text | grep -qx "$LOG_GROUP"; then
  echo "Log Group já existe."
else
  aws logs create-log-group \
    --log-group-name "$LOG_GROUP" \
    --region "$REGION"
  echo "Log Group criado."
fi

echo "Aplicando retenção de ${RETENTION_DAYS} dias no Log Group..."
aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP" \
  --retention-in-days "$RETENTION_DAYS" \
  --region "$REGION"

echo "Verificando se o documento ${DOCUMENT_NAME} existe..."
if aws ssm get-document \
  --name "$DOCUMENT_NAME" \
  --region "$REGION" >/dev/null 2>&1; then

  echo "Documento já existe. Atualizando conteúdo..."
  aws ssm update-document \
    --name "$DOCUMENT_NAME" \
    --content "file://${TMP_JSON}" \
    --document-version "\$LATEST" \
    --region "$REGION" >/dev/null

  echo "Criando nova versão padrão do documento..."
  LATEST_VERSION="$(
    aws ssm update-document-default-version \
      --name "$DOCUMENT_NAME" \
      --document-version "\$LATEST" \
      --region "$REGION" \
      --query 'Description.DocumentVersion' \
      --output text 2>/dev/null || true
  )"

  if [[ -n "${LATEST_VERSION}" && "${LATEST_VERSION}" != "None" ]]; then
    echo "Versão padrão ajustada para: ${LATEST_VERSION}"
  else
    echo "Aviso: não foi possível confirmar a nova versão padrão automaticamente."
  fi

else
  echo "Documento não existe. Criando..."
  aws ssm create-document \
    --name "$DOCUMENT_NAME" \
    --document-type "Session" \
    --document-format "JSON" \
    --content "file://${TMP_JSON}" \
    --region "$REGION" >/dev/null
  echo "Documento criado."
fi

echo
echo "Validação final:"
echo "----------------"

echo "[1/2] Log Group:"
aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --region "$REGION" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].[logGroupName,retentionInDays]" \
  --output table

echo "[2/2] Documento SSM:"
aws ssm get-document \
  --name "$DOCUMENT_NAME" \
  --region "$REGION" \
  --query '{Name:Name,DocumentType:DocumentType,Status:Status}' \
  --output table

echo
echo "Concluído com sucesso."