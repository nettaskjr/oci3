#!/bin/bash
# OCI User Data Script

# Log de execução para debug
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Iniciando configuração da instância (Branch Persistencia)..."

# 1. Atualização e Instalação de Pacotes Básicos
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git ncdu

# 2. Instalação e Configuração do Cloudflared
echo "Instalando Cloudflared (${cloudflared_version})..."
URL="https://github.com/cloudflare/cloudflared/releases/download/${cloudflared_version}/cloudflared-linux-arm64.deb"

if ! curl -L --fail --output cloudflared.deb "$URL"; then
  echo "Fallback para latest..."
  curl -L --fail --output cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
fi
dpkg -i cloudflared.deb

echo "Registrando túnel..."
cloudflared service install "${tunnel_token}" || true
systemctl restart cloudflared

# 3. Instalação do K3s
export K3S_KUBECONFIG_MODE="644"
# Instalação padrão (usa disco de boot /var/lib/rancher)
curl -sfL https://get.k3s.io | sh -

# Configurar Kubeconfig para o usuário da instância (ubuntu)
USER_HOME="/home/${user_instance}"
mkdir -p $USER_HOME/.kube
cp /etc/rancher/k3s/k3s.yaml $USER_HOME/.kube/config
chown -R ${user_instance}:${user_instance} $USER_HOME/.kube
echo "export KUBECONFIG=$USER_HOME/.kube/config" >> $USER_HOME/.bashrc

# 4. GitOps: Clonar Repositório de Stack e instalacao dos apps via manifestos
STACK_DIR="$USER_HOME/.stack"
git clone "${github_repo}" $STACK_DIR || echo "Falha ao clonar repo"

if [ -d "$STACK_DIR" ]; then
  echo "Configurando variáveis..."
  find $STACK_DIR -name "*.yaml" -type f -exec sed -i "s|<<seu-dominio>>|${domain_name}|g" {} +
  find $STACK_DIR -name "*.yaml" -type f -exec sed -i "s|<<user-home>>|$USER_HOME|g" {} +
  
  chown -R ${user_instance}:${user_instance} $STACK_DIR
  
  # Garantir estabilidade e aplicar
  echo "Aguardando estabilidade do K3s..."
  
  # O restart ajuda a garantir que o IP correto da OCI seja capturado pelo K3s
  systemctl restart k3s
  
  # Aguardar API Server (loop robusto com kubectl)
  timeout 60s bash -c "until kubectl get --raw='/readyz' > /dev/null 2>&1; do sleep 2; done"
  
  # Aguardar Nodes
  kubectl wait --for=condition=Ready node --all --timeout=60s
  
  # Aguardar CRDs do Traefik de forma segura
  echo "Aguardando criação dos CRDs do Traefik..."
  timeout 120s bash -c "until kubectl get crd ingressroutes.traefik.io > /dev/null 2>&1; do echo 'Aguardando CRD...'; sleep 5; done"
  
  # 5. Aplicar os manifestos
  echo "#### Aplicando Portainer..."
  kubectl apply -f $STACK_DIR/Portainer/portainer.yaml

  echo "#### Aplicando Page Error..."
  kubectl apply -f $STACK_DIR/k8s-error-page/
  
  echo "#### Aplicando Monitoramento..."
  kubectl apply -f $STACK_DIR/k8s-monitoring/

  # 8. Notificar Discord
  if [ -n "${discord_webhook_url}" ]; then
    curl -H "Content-Type: application/json" \
    -d '{"content": "🚀 **Infra OCI Pronta!**\n- 🖥️ SSH: `ssh ssh.${domain_name}` (Zero Trust)\n- ☸️ Kubernetes: K3s Up\n- 🐳 Portainer: https://portainer.${domain_name}\n- 📊 Grafana: https://grafana.${domain_name}\n- 🔍 Loki Logs: Ativo\n\n_Deploy finalizado com sucesso!_"}' \
    "${discord_webhook_url}"
  fi

  echo "Configuração finalizada."
else
  echo "Repositório de Stack não encontrado."
fi