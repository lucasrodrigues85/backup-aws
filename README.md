# 🔄 Sistema de Backup Automatizado para AWS S3

[![GitHub release](https://img.shields.io/github/release/lucasrodrigues85/backup-aws.svg)](https://github.com/lucasrodrigues85/backup-aws/releases)
[![GitHub license](https://img.shields.io/github/license/lucasrodrigues85/backup-aws.svg)](https://github.com/lucasrodrigues85/backup-aws/blob/main/LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/lucasrodrigues85/backup-aws.svg)](https://github.com/lucasrodrigues85/backup-aws/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/lucasrodrigues85/backup-aws.svg)](https://github.com/lucasrodrigues85/backup-aws/network)
[![GitHub issues](https://img.shields.io/github/issues/lucasrodrigues85/backup-aws.svg)](https://github.com/lucasrodrigues85/backup-aws/issues)
[![Python](https://img.shields.io/badge/Python-3.7+-blue.svg)](https://www.python.org/downloads/)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![AWS S3](https://img.shields.io/badge/AWS-S3-orange.svg)](https://aws.amazon.com/s3/)
[![Telegram](https://img.shields.io/badge/Telegram-Bot-blue.svg)](https://core.telegram.org/bots)

Um sistema robusto e completo para backup automatizado de arquivos e diretórios para AWS S3, com notificações via Telegram e validação de integridade avançada.

## ✨ Características

- **Backup automatizado** com agendamento via cron
- **Notificações em tempo real** via Telegram
- **Validação de integridade** completa com verificação de hash
- **Arquivamento inteligente** com controle de profundidade de divisão
- **Gestão de logs** com rotação automática
- **Interface de linha de comando** amigável
- **Configuração flexível** via arquivo JSON
- **Suporte a múltiplas pastas** com configurações individuais
- **Classes de armazenamento S3** personalizáveis (incluindo Deep Archive)

## 🏗️ Arquitetura

O sistema é composto por quatro componentes principais:

1. **`backup_script.sh`** - Script bash para execução do backup e upload para S3
2. **`backup_scheduler.py`** - Orquestrador Python com validação e notificações
3. **`cron_setup.sh`** - Script de configuração automática do cron
4. **`config.json`** - Arquivo de configuração centralizada

## 📋 Pré-requisitos

### Sistema
- Linux (testado em Ubuntu/Debian)
- Python 3.7+
- Bash 4.0+
- `rclone` configurado com credenciais AWS S3
- `parallel` (GNU parallel)
- `tar`, `gzip`, `md5sum`

### Credenciais necessárias
- **AWS S3**: Bucket configurado com rclone
- **Telegram Bot**: Token e Chat ID para notificações

## 🚀 Instalação

### 1. Clone o repositório
```bash
git clone https://github.com/lucasrodrigues85/backup-aws.git
cd backup-aws
```

### 2. Configure o rclone para AWS S3
```bash
rclone config
# Siga as instruções para configurar um remote chamado "AmazonS3"
```

### 3. Instale dependências do sistema
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install python3 python3-pip python3-venv parallel

# CentOS/RHEL
sudo yum install python3 python3-pip parallel
```

### 4. Configure o arquivo de configuração
```bash
cp config.json.example config.json
nano config.json
```

### 5. Execute o setup automático
```bash
chmod +x cron_setup.sh
./cron_setup.sh
```

## ⚙️ Configuração

### Arquivo config.json

```json
{
  "telegram": {
    "token": "SEU_TOKEN_DO_TELEGRAM",
    "chat_id": "SEU_CHAT_ID"
  },
  "s3": {
    "bucket": "nome-do-seu-bucket",
    "storage_class": "DEEP_ARCHIVE"
  },
  "backup": {
    "script_path": "/caminho/para/backup.sh",
    "temp_dir": "/tmp",
    "max_size_gb": 1024
  },
  "folders": [
    {
      "name": "config",
      "path": "/mnt/storage/config",
      "split_depth": 1,
      "enabled": true
    }
  ],
  "logging": {
    "level": "INFO",
    "keep_logs_days": 30
  },
  "validation": {
    "enabled": true,
    "keep_local_copy": false,
    "deep_validation": true
  }
}
```

### Parâmetros importantes

#### Split Depth
Controla como os diretórios são divididos em arquivos separados:
- `0`: Backup da pasta inteira como um único arquivo
- `1`: Cada subpasta vira um arquivo separado
- `2`: Cada subpasta de subpasta vira um arquivo separado

**Exemplo para `/storage/user1`:**
- Depth 0: `user1.tar.gz` (tudo junto)
- Depth 1: `user1/documents.tar.gz`, `user1/photos.tar.gz`, etc.
- Depth 2: `user1/documents/2024.tar.gz`, `user1/photos/vacation.tar.gz`, etc.

#### Classes de Armazenamento S3
- `STANDARD`: Acesso frequente
- `STANDARD_IA`: Acesso infrequente
- `GLACIER`: Arquivo de longo prazo
- `DEEP_ARCHIVE`: Arquivo de muito longo prazo (mais barato)

## 🔧 Uso

### Execução manual
```bash
# Executar todos os backups
python3 backup_scheduler.py

# Executar apenas uma pasta específica
python3 backup_scheduler.py --folder config

# Modo dry-run (teste sem executar)
python3 backup_scheduler.py --dry-run

# Usar arquivo de configuração alternativo
python3 backup_scheduler.py --config /path/to/other/config.json
```

### Execução via cron (automática)
O script `cron_setup.sh` configura automaticamente o cron para executar todo domingo às 3h da manhã.

```bash
# Ver cron jobs atuais
crontab -l

# Editar manualmente
crontab -e

# Ver logs do cron
tail -f logs/cron.log
```

## 📊 Monitoramento e Logs

### Estrutura de logs
```
logs/
├── backup_20241205.log        # Log diário detalhado
├── cron.log                   # Log do cron job
└── crontab_backup_*.txt       # Backups do crontab
```

### Verificar status
```bash
# Logs em tempo real
tail -f logs/backup_$(date +%Y%m%d).log

# Status do serviço cron
systemctl status cron

# Últimas execuções
grep "Processo finalizado" logs/backup_*.log | tail -5
```

## 🔒 Validação e Integridade

O sistema oferece múltiplas camadas de validação:

1. **Hash MD5** de todos os arquivos antes do backup
2. **Verificação de integridade** do arquivo tar.gz
3. **Contagem de arquivos** entre original e backup
4. **Validação profunda** opcional com extração e comparação
5. **Verificação S3** após upload

### Configurações de validação
```json
"validation": {
  "enabled": true,              // Ativa validação básica
  "keep_local_copy": false,     // Mantém cópia local para validação
  "deep_validation": true       // Extrai e compara arquivo por arquivo
}
```

## 🔔 Notificações Telegram

### Configurar bot do Telegram
1. Converse com [@BotFather](https://t.me/BotFather)
2. Crie um novo bot: `/newbot`
3. Copie o token fornecido
4. Adicione o bot a um chat e obtenha o Chat ID

### Tipos de notificação
- ✅ Início do processo de backup
- 🔄 Início de cada pasta individual
- ✅ Sucesso de cada backup
- ❌ Falhas com detalhes do erro
- 📊 Relatório final com estatísticas

## 🛠️ Troubleshooting

### Problemas comuns

#### Erro de permissão
```bash
chmod +x backup.sh backup_scheduler.py cron_setup.sh
```

#### Rclone não configurado
```bash
rclone config show
# Se vazio, execute: rclone config
```

#### Falta de espaço em /tmp
```json
{
  "backup": {
    "temp_dir": "/mnt/storage/temp"  // Use outro diretório
  }
}
```

#### Telegram não recebe mensagens
- Verifique se o bot foi adicionado ao chat
- Confirme o Chat ID correto
- Teste: `curl -X GET "https://api.telegram.org/bot<TOKEN>/getUpdates"`

### Logs de debug
```bash
# Ativar modo verbose
python3 backup_scheduler.py --verbose

# Ver configuração carregada
python3 backup_scheduler.py --dry-run
```

## 📈 Otimização e Performance

### Para grandes volumes de dados
- Ajuste `max_size_gb` conforme seu caso
- Use `split_depth` apropriado para evitar arquivos muito grandes
- Configure `keep_local_copy: false` para economizar espaço
- Use `DEEP_ARCHIVE` para custos menores

### Para execução mais rápida
- Desative `deep_validation` se confiar na validação básica
- Use SSD para `temp_dir`
- Configure `upload_concurrency` no rclone

## 🔄 Restauração

Para restaurar um backup:

```bash
# Baixar arquivo específico
rclone copy AmazonS3:seu-bucket/backup-name/pasta.tar.gz ./

# Extrair
tar -xzf pasta.tar.gz

# Ou restaurar diretamente
rclone copy AmazonS3:seu-bucket/backup-name/ ./restore/ --include "*.tar.gz"
```

## 🤝 Contribuição

Contribuições são bem-vindas! Por favor:

1. Fork o projeto
2. Crie uma branch para sua feature (`git checkout -b feature/nova-funcionalidade`)
3. Commit suas mudanças (`git commit -am 'Adiciona nova funcionalidade'`)
4. Push para a branch (`git push origin feature/nova-funcionalidade`)
5. Abra um Pull Request

## 📄 Licença

Este projeto está licenciado sob a Licença MIT - veja o arquivo [LICENSE](LICENSE) para detalhes.

## 🙏 Agradecimentos

- [rclone](https://rclone.org/) - Ferramenta fantástica para sincronização em nuvem
- [GNU Parallel](https://www.gnu.org/software/parallel/) - Processamento paralelo eficiente
- [python-telegram-bot](https://github.com/python-telegram-bot/python-telegram-bot) - API do Telegram para Python

---

## ☕ Apoie o projeto

Se este projeto foi útil para você, considere me pagar um café! ☕

Sua contribuição ajuda a manter o projeto ativo e desenvolver novas funcionalidades.

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow.svg?style=flat-square&logo=buy-me-a-coffee)](https://www.coff.ee/lucasmrodr0)

**PIX:** `5ba71767-62af-4116-8cd4-119fcfe35e54` (chave aleatória)

Muito obrigado pelo seu apoio! 🚀
