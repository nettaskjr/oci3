#!/bin/bash
# OCI User Data Script

# Log de execução para debug
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Iniciando configuração da instância..."

# 1. Atualização e Instalação de Pacotes Básicos
echo "Atualizando e instalando pacotes..."
sudo apt-get update -y
sudo apt-get install -y curl git xfsprogs ncdu

# 1.1 Configuração do Volume Persistente (Data Volume)
# OCI Paravirtualized attachment geralmente aparece como /dev/sdb se o boot for sda
DATA_DEVICE="/dev/sdb"
MOUNT_POINT="/var/lib/rancher"

echo "Configurando volume de dados persistente em $DATA_DEVICE..."

# Aguardar device aparecer (Timeout 2 min)
count=0
while [ ! -b $DATA_DEVICE ] && [ $count -lt 24 ]; do 
  echo "Aguardando disco $DATA_DEVICE... ($count/24)"
  sleep 5
  count=$((count+1))
done

if [ -b $DATA_DEVICE ]; then
  # Verificar se já está formatado (blkid retorna exit code 0 se tiver fs)
  if ! blkid $DATA_DEVICE; then
      echo "Formatando $DATA_DEVICE como XFS..."
      mkfs.xfs $DATA_DEVICE
  fi

  # Criar mountpoint e montar
  mkdir -p $MOUNT_POINT
  if ! grep -qs "$MOUNT_POINT" /etc/fstab; then
    echo "$DATA_DEVICE $MOUNT_POINT xfs defaults 0 0" >> /etc/fstab
  fi
  mount -a
  echo "Volume montado em $MOUNT_POINT"
else
  echo "AVISO: Disco $DATA_DEVICE não encontrado após timeout. Pulando configuração de storage."
fi

# 2. Configuração de Firewall (Iptables)
echo "Configurando firewall..."
# Limpar regras de firewall da Oracle (iptables) para permitir comunicação CNI
# Isso evita erros de "no route to host" entre Pods e API Server
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
netfilter-persistent save

# 3. Instalação e Configuração do Cloudflared
echo "Baixando e instalando o Cloudflared..."

# Tentar versão específica
URL="https://github.com/cloudflare/cloudflared/releases/download/${cloudflared_version}/cloudflared-linux-arm64.deb"
echo "Tentando baixar: $URL"

if curl -L --fail --output cloudflared.deb "$URL"; then
  echo "Download da versão ${cloudflared_version} com sucesso."
else
  echo "ERRO: Falha ao baixar versão ${cloudflared_version} (404?). Tentando fallback para 'latest'..."
  if curl -L --fail --output cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"; then
    echo "Fallback para latest com sucesso."
  else
    echo "FATAL: Não foi possível baixar cloudflared (Nem versão fixa nem latest)."
    # Notificar falha crítica no Discord
    if [ -n "${discord_webhook_url}" ]; then
       curl -H "Content-Type: application/json" -d '{"content": "❌ **FALHA CRÍTICA:** Não foi possível baixar o Cloudflared na instância OCI. Verifique a internet e as URLs."}' "${discord_webhook_url}"
    fi
    exit 1
  fi
fi

# Instalar
dpkg -i cloudflared.deb

# Registrar Serviço
# O token é injetado via Terraform templatefile
echo "Registrando túnel..."
if cloudflared service install "${tunnel_token}"; then
  echo "Túnel registrado com sucesso."
  systemctl daemon-reload
  systemctl restart cloudflared
else
  echo "FATAL: Falha ao registrar túnel. Verifique se o Token é válido."
  if [ -n "${discord_webhook_url}" ]; then
       curl -H "Content-Type: application/json" -d '{"content": "❌ **FALHA CRÍTICA:** Token do Cloudflare Tunnel inválido ou erro no registro."}' "${discord_webhook_url}"
  fi
fi
