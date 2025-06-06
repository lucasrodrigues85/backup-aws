#!/bin/bash

# Script para configurar o cron job do backup automatizado
# Uso: ./setup_cron.sh

set -e

# Configurações
SCRIPT_DIR="/mnt/storage/config/rotina-backup"
PYTHON_SCRIPT="$SCRIPT_DIR/agendamento.py"
LOG_DIR="$SCRIPT_DIR/logs"
CRON_LOG="$LOG_DIR/cron.log"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔧 Configurando backup automatizado${NC}"

# Verifica se o script existe
if [[ ! -f "$PYTHON_SCRIPT" ]]; then
    echo -e "${RED}❌ Script não encontrado: $PYTHON_SCRIPT${NC}"
    exit 1
fi

# Cria diretório de logs se não existir
mkdir -p "$LOG_DIR"

# Torna o script executável
chmod +x "$PYTHON_SCRIPT"

# Backup do crontab atual
echo -e "${YELLOW}📋 Fazendo backup do crontab atual...${NC}"
crontab -l > "$LOG_DIR/crontab_backup_$(date +%Y%m%d_%H%M%S).txt" 2>/dev/null || true

# Remove entradas antigas do backup (se existirem)
echo -e "${YELLOW}🧹 Removendo configurações antigas...${NC}"
crontab -l 2>/dev/null | grep -v "$PYTHON_SCRIPT" | crontab - 2>/dev/null || true

# Adiciona nova entrada do cron
echo -e "${YELLOW}⚙️ Configurando novo cron job...${NC}"
(crontab -l 2>/dev/null; echo "# Backup automatizado - Executa todo domingo às 3h da manhã") | crontab -
(crontab -l 2>/dev/null; echo "0 3 * * 0 cd $SCRIPT_DIR && python3 $PYTHON_SCRIPT >> $CRON_LOG 2>&1") | crontab -

# Verifica se foi configurado corretamente
echo -e "${GREEN}✅ Configuração do cron concluída!${NC}"
echo
echo -e "${YELLOW}📋 Cron jobs atuais:${NC}"
crontab -l

echo
echo -e "${GREEN}ℹ️ Informações importantes:${NC}"
echo "• Backup executará todo domingo às 3h da manhã"
echo "• Logs serão salvos em: $CRON_LOG"
echo "• Logs detalhados em: $LOG_DIR/"
echo "• Para testar manualmente: cd $SCRIPT_DIR && python3 $PYTHON_SCRIPT"
echo "• Para desabilitar: crontab -e (remover a linha do backup)"

echo
echo -e "${YELLOW}🔍 Para verificar se está funcionando:${NC}"
echo "• Próxima execução: $(date -d 'next sunday 03:00')"
echo "• Verificar logs: tail -f $CRON_LOG"
echo "• Status do cron: systemctl status cron"

# Teste de configuração
echo
echo -e "${YELLOW}🧪 Testando configuração...${NC}"
if cd "$SCRIPT_DIR" && python3 "$PYTHON_SCRIPT" --dry-run; then
    echo -e "${GREEN}✅ Teste de configuração passou!${NC}"
else  
    echo -e "${RED}❌ Erro na configuração. Verifique o arquivo config.json${NC}"
    exit 1
fi

echo
echo -e "${GREEN}🎉 Setup concluído com sucesso!${NC}"
