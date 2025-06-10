#!/usr/bin/env python3
"""
Sistema de Backup Automatizado
Autor: Lucas M. Rodrigues
Versão: 2.0
Data: 01/2025

Executa backups automatizados com validação completa e notificações via Telegram.
Configurações são carregadas de arquivo externo para maior segurança.
"""

import os
import sys
import json
import subprocess
import tarfile
import asyncio
import venv
import hashlib
import tempfile
import logging
import argparse
from datetime import datetime, timedelta
from pathlib import Path


class BackupManager:
    def __init__(self, config_file="config.json"):
        self.config_file = config_file
        self.config = self.load_config()
        self.setup_logging()
        self.logger = logging.getLogger(__name__)
        
    def load_config(self):
        """Carrega configurações do arquivo JSON."""
        script_dir = Path(__file__).parent
        config_path = script_dir / self.config_file
        
        if not config_path.exists():
            self.create_default_config(config_path)
            print(f"❌ Arquivo de configuração criado em: {config_path}")
            print("Por favor, edite o arquivo com suas configurações e execute novamente.")
            sys.exit(1)
            
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                config = json.load(f)
            self.validate_config(config)
            return config
        except Exception as e:
            print(f"❌ Erro ao carregar configuração: {e}")
            sys.exit(1)
    
    def create_default_config(self, config_path):
        """Cria arquivo de configuração padrão."""
        default_config = {
            "telegram": {
                "token": "SEU_TOKEN_DO_TELEGRAM_AQUI",
                "chat_id": "SEU_CHAT_ID_AQUI"
            },
            "s3": {
                "bucket": "SEU_BUCKET_S3_AQUI",
                "storage_class": "DEEP_ARCHIVE"
            },
            "backup": {
                "script_path": "/mnt/storage/config/rotina-backup/backup.sh",
                "temp_dir": "/tmp",
                "max_size_gb": 1024
            },
            "folders": [
                {
                    "name": "config",
                    "path": "/mnt/storage/config",
                    "split_depth": 1,
                    "enabled": True
                }
            ],
            "logging": {
                "level": "INFO",
                "keep_logs_days": 30
            },
            "validation": {
                "enabled": True,
                "keep_local_copy": False,
                "deep_validation": True
            }
        }
        
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(default_config, f, indent=2, ensure_ascii=False)
    
    def validate_config(self, config):
        """Valida se a configuração está completa."""
        required_keys = ['telegram', 's3', 'backup', 'folders']
        for key in required_keys:
            if key not in config:
                raise ValueError(f"Chave obrigatória '{key}' não encontrada na configuração")
        
        if config['telegram']['token'] == "SEU_TOKEN_DO_TELEGRAM_AQUI":
            raise ValueError("Configure o token do Telegram no arquivo config.json")
            
        if config['s3']['bucket'] == "SEU_BUCKET_S3_AQUI":
            raise ValueError("Configure o bucket S3 no arquivo config.json")
    
    def setup_logging(self):
        """Configura sistema de logging."""
        log_dir = Path(__file__).parent / "logs"
        log_dir.mkdir(exist_ok=True)
        
        log_level = getattr(logging, self.config.get('logging', {}).get('level', 'INFO'))
        log_file = log_dir / f"backup_{datetime.now().strftime('%Y%m%d')}.log"
        
        # Configuração de logging
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file, encoding='utf-8'),
                logging.StreamHandler(sys.stdout)
            ]
        )
        
        # Limpeza de logs antigos
        self.cleanup_old_logs(log_dir)
    
    def cleanup_old_logs(self, log_dir):
        """Remove logs antigos baseado na configuração."""
        try:
            keep_days = self.config.get('logging', {}).get('keep_logs_days', 30)
            cutoff = datetime.now() - timedelta(days=keep_days)
            
            for log_file in log_dir.glob("backup_*.log"):
                if log_file.stat().st_mtime < cutoff.timestamp():
                    log_file.unlink()
                    self.logger.info(f"Log antigo removido: {log_file}")
        except Exception as e:
            self.logger.warning(f"Erro ao limpar logs antigos: {e}")

    def create_virtualenv(self, venv_dir):
        """Create a virtual environment if it does not exist."""
        if not os.path.exists(venv_dir):
            self.logger.info(f'Criando ambiente virtual em {venv_dir}...')
            venv.create(venv_dir, with_pip=True)
        else:
            self.logger.debug(f'Ambiente virtual já existe em {venv_dir}.')

    def install_module(self, module_name, python_executable):
        """Install a module in the virtual environment."""
        try:
            subprocess.check_call([python_executable, '-m', 'pip', 'install', module_name], 
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.logger.debug(f"Módulo {module_name} instalado com sucesso")
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Erro ao instalar módulo {module_name}: {e}")
            raise

    def calculate_directory_hash(self, path):
        """Calcula hash MD5 de todos os arquivos em uma pasta."""
        hash_md5 = hashlib.md5()
        
        for root, dirs, files in os.walk(path):
            dirs.sort()
            files.sort()
            
            for filename in files:
                filepath = os.path.join(root, filename)
                try:
                    with open(filepath, 'rb') as f:
                        rel_path = os.path.relpath(filepath, path)
                        hash_md5.update(rel_path.encode('utf-8'))
                        
                        for chunk in iter(lambda: f.read(4096), b""):
                            hash_md5.update(chunk)
                except (IOError, OSError) as e:
                    self.logger.warning(f"Erro ao ler arquivo {filepath}: {e}")
                    continue
        
        return hash_md5.hexdigest()

    def validar_backup_completo(self, tar_file, original_path):
        """Valida se o backup está íntegro comparando com a pasta original."""
        if not self.config.get('validation', {}).get('deep_validation', True):
            return True
            
        self.logger.info(f"Validando backup {tar_file} contra {original_path}...")
        
        if not os.path.exists(tar_file):
            self.logger.error(f"Arquivo {tar_file} não encontrado")
            return False
        
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                with tarfile.open(tar_file, "r:gz") as tar:
                    tar.extractall(temp_dir)
                
                # Compara estrutura de arquivos
                original_files = set()
                for root, dirs, files in os.walk(original_path):
                    for file in files:
                        rel_path = os.path.relpath(os.path.join(root, file), original_path)
                        original_files.add(rel_path)
                
                extracted_files = set()
                for root, dirs, files in os.walk(temp_dir):
                    for file in files:
                        rel_path = os.path.relpath(os.path.join(root, file), temp_dir)
                        extracted_files.add(rel_path)
                
                missing_files = original_files - extracted_files
                extra_files = extracted_files - original_files
                
                if missing_files:
                    self.logger.error(f"Arquivos faltando no backup: {missing_files}")
                    return False
                
                if extra_files:
                    self.logger.warning(f"Arquivos extras no backup: {extra_files}")
                
                # Validação de hash dos arquivos (amostragem para arquivos grandes)
                files_to_check = list(original_files)
                if len(files_to_check) > 100:  # Amostragem para muitos arquivos
                    import random
                    files_to_check = random.sample(files_to_check, 100)
                
                for rel_path in files_to_check:
                    original_file = os.path.join(original_path, rel_path)
                    extracted_file = os.path.join(temp_dir, rel_path)
                    
                    if not os.path.exists(extracted_file):
                        self.logger.error(f"Arquivo {rel_path} não encontrado no backup extraído")
                        return False
                    
                    with open(original_file, 'rb') as f1, open(extracted_file, 'rb') as f2:
                        hash1 = hashlib.md5(f1.read()).hexdigest()
                        hash2 = hashlib.md5(f2.read()).hexdigest()
                        
                        if hash1 != hash2:
                            self.logger.error(f"Hash diferente para arquivo {rel_path}")
                            return False
                
                self.logger.info(f"Backup validado com sucesso: {len(original_files)} arquivos verificados")
                return True
                
        except Exception as e:
            self.logger.error(f"Erro durante validação: {e}")
            return False

    def gerar_lista_arquivos(self, path, output_file):
        """Gera um arquivo TXT com a lista de todos os arquivos da pasta."""
        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(f"Lista de arquivos de: {path}\n")
                f.write(f"Gerado em: {datetime.now().isoformat()}\n")
                f.write("-" * 50 + "\n\n")
                
                total_files = 0
                total_size = 0
                
                for root, dirs, files in os.walk(path):
                    dirs.sort()
                    files.sort()
                    
                    for filename in files:
                        filepath = os.path.join(root, filename)
                        try:
                            size = os.path.getsize(filepath)
                            rel_path = os.path.relpath(filepath, path)
                            f.write(f"{rel_path} ({size} bytes)\n")
                            total_files += 1
                            total_size += size
                        except OSError:
                            f.write(f"{rel_path} (erro ao obter tamanho)\n")
                            total_files += 1
                
                f.write(f"\n" + "-" * 50 + "\n")
                f.write(f"Total de arquivos: {total_files}\n")
                f.write(f"Tamanho total: {total_size} bytes ({total_size/(1024**3):.2f} GB)\n")
                
            self.logger.info(f"Lista de arquivos gerada: {output_file}")
            return True
            
        except Exception as e:
            self.logger.error(f"Erro ao gerar lista de arquivos: {e}")
            return False

    async def enviar_mensagem(self, mensagem):
        """Envia uma mensagem pelo Telegram."""
        try:
            import telegram
            from telegram import Bot

            token = self.config['telegram']['token']
            chat_id = self.config['telegram']['chat_id']
            
            bot = Bot(token=token)
            await bot.send_message(chat_id=chat_id, text=mensagem, parse_mode='HTML')
            self.logger.debug(f"Mensagem enviada: {mensagem[:50]}...")
            
        except Exception as e:
            self.logger.error(f"Erro ao enviar mensagem Telegram: {e}")

    async def executar_backup(self, folder_config):
        """Executa o script de backup com validação completa."""
        name = folder_config['name']
        path = folder_config['path']
        split_depth = folder_config['split_depth']
        
        try:
            temp_dir = self.config['backup']['temp_dir']
            tar_path = f"{temp_dir}/{name}.tar.gz"
            txt_path = f"{temp_dir}/{name}_files.txt"
            
            self.logger.info(f"Iniciando backup para {name} (split-depth: {split_depth})")
            
            # Verifica se o caminho existe
            if not os.path.exists(path):
                raise FileNotFoundError(f"Caminho não encontrado: {path}")
            
            # Gera lista de arquivos antes do backup
            if not self.gerar_lista_arquivos(path, txt_path):
                await self.enviar_mensagem(f"❌ Falha ao gerar lista de arquivos para <b>{name}</b>")
                return False
            
            # Calcula hash da pasta original
            if self.config.get('validation', {}).get('enabled', True):
                self.logger.info(f"Calculando hash original para {name}...")
                original_hash = self.calculate_directory_hash(path)
                self.logger.info(f"Hash original da pasta {name}: {original_hash}")
            
            # Prepara comando de backup
            comando = [
                self.config['backup']['script_path'],
                "--bucket", self.config['s3']['bucket'],
                "--name", name,
                "--path", path,
                "--split-depth", str(split_depth),
                "--storage-class", self.config['s3'].get('storage_class', 'DEEP_ARCHIVE')
            ]
            
            if self.config.get('validation', {}).get('enabled', True):
                comando.append("--validate")
                
            if self.config.get('validation', {}).get('keep_local_copy', False):
                comando.append("--keep-local")

            self.logger.info(f"Executando comando: {' '.join(comando)}")
            
            # Executa backup
            resultado = subprocess.run(
                comando, 
                check=True, 
                capture_output=True, 
                text=True,
                timeout=3600  # Timeout de 1 hora
            )
            
            self.logger.info(f"Backup executado com sucesso para {name}")
            self.logger.debug(f"Saída do comando: {resultado.stdout}")
            
            # Validação local se arquivo existe
            if os.path.exists(tar_path) and self.config.get('validation', {}).get('deep_validation', True):
                if self.validar_backup_completo(tar_path, path):
                    await self.enviar_mensagem(f"✅ Backup e validação completos para <b>{name}</b>")
                    return True
                else:
                    await self.enviar_mensagem(f"❌ Falha na validação do backup para <b>{name}</b>")
                    return False
            else:
                # Confia na validação do script
                if "Validation passed" in resultado.stdout or "uploaded successfully" in resultado.stdout:
                    await self.enviar_mensagem(f"✅ Backup validado remotamente para <b>{name}</b>")
                    return True
                else:
                    await self.enviar_mensagem(f"⚠️ Backup enviado mas validação inconclusiva para <b>{name}</b>")
                    return True

        except subprocess.TimeoutExpired:
            mensagem_erro = f"❌ Timeout no backup para <b>{name}</b> (>1h)"
            self.logger.error(mensagem_erro)
            await self.enviar_mensagem(mensagem_erro)
            return False
            
        except subprocess.CalledProcessError as e:
            mensagem_erro = f"❌ Erro ao executar backup para <b>{name}</b>: {e}"
            self.logger.error(f"Stdout: {e.stdout}")
            self.logger.error(f"Stderr: {e.stderr}")
            await self.enviar_mensagem(mensagem_erro)
            return False
            
        except Exception as e:
            mensagem_erro = f"❌ Erro inesperado no backup para <b>{name}</b>: {e}"
            self.logger.error(mensagem_erro)
            await self.enviar_mensagem(mensagem_erro)
            return False

    async def executar_todos_backups(self):
        """Executa todos os backups configurados."""
        inicio = datetime.now()
        self.logger.info("🚀 Iniciando processo de backup automatizado")
        
        await self.enviar_mensagem("🚀 <b>Iniciando backup automatizado</b>")
        
        folders_habilitadas = [f for f in self.config['folders'] if f.get('enabled', True)]
        sucessos = 0
        falhas = 0

        for folder_config in folders_habilitadas:
            name = folder_config['name']
            
            await self.enviar_mensagem(
                f"🔄 Iniciando backup para <b>{name}</b> (split-depth: {folder_config['split_depth']})"
            )
            
            sucesso = await self.executar_backup(folder_config)
            
            if sucesso:
                sucessos += 1
                await self.enviar_mensagem(f"✅ Backup para <b>{name}</b> concluído com sucesso!")
            else:
                falhas += 1
                await self.enviar_mensagem(f"❌ Falha no backup para <b>{name}</b>")
        
        # Relatório final
        fim = datetime.now()
        duracao = fim - inicio
        total = sucessos + falhas
        
        relatorio = f"""📊 <b>Relatório Final de Backup</b>
        
✅ Sucessos: {sucessos}/{total}
❌ Falhas: {falhas}
⏱️ Duração: {duracao}
📅 Concluído em: {fim.strftime('%d/%m/%Y %H:%M:%S')}"""
        
        await self.enviar_mensagem(relatorio)
        self.logger.info(f"Processo finalizado: {sucessos}/{total} sucessos, duração: {duracao}")
        
        return sucessos == total

    async def setup_environment(self):
        """Configura ambiente virtual e dependências."""
        script_dir = Path(__file__).parent
        venv_dir = script_dir / 'venv'
        
        # Cria ambiente virtual
        self.create_virtualenv(venv_dir)
        
        # Caminho para o executável Python do ambiente virtual
        if os.name == 'nt':  # Windows
            python_executable = venv_dir / 'Scripts' / 'python.exe'
        else:  # Unix/Linux
            python_executable = venv_dir / 'bin' / 'python'
        
        # Instala módulos necessários
        required_modules = ['python-telegram-bot']
        for module in required_modules:
            self.install_module(module, str(python_executable))
        
        # Re-executa com o Python do ambiente virtual se necessário
        if sys.executable != str(python_executable):
            self.logger.info(f'Re-executando script com {python_executable}...')
            os.execv(str(python_executable), [str(python_executable)] + sys.argv)

def main():
    parser = argparse.ArgumentParser(description='Sistema de Backup Automatizado')
    parser.add_argument('--config', default='config.json', 
                       help='Arquivo de configuração (padrão: config.json)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Executa sem fazer backup real')
    parser.add_argument('--folder', 
                       help='Executa backup apenas para pasta específica')
    
    args = parser.parse_args()
    
    try:
        manager = BackupManager(args.config)
        
        if args.dry_run:
            manager.logger.info("🔍 Modo dry-run ativado")
            print("Configuração carregada com sucesso!")
            print(f"Pastas configuradas: {len(manager.config['folders'])}")
            for folder in manager.config['folders']:
                status = "✅" if folder.get('enabled', True) else "❌"
                print(f"  {status} {folder['name']}: {folder['path']} (depth: {folder['split_depth']})")
            return
        
        # Filtra pasta específica se solicitado
        if args.folder:
            manager.config['folders'] = [
                f for f in manager.config['folders'] 
                if f['name'] == args.folder and f.get('enabled', True)
            ]
            if not manager.config['folders']:
                print(f"❌ Pasta '{args.folder}' não encontrada ou desabilitada")
                return
        
        # Executa setup e backup
        asyncio.run(manager.setup_environment())
        success = asyncio.run(manager.executar_todos_backups())
        
        sys.exit(0 if success else 1)
        
    except KeyboardInterrupt:
        print("\n⚠️ Processo interrompido pelo usuário")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Erro crítico: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
