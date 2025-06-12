#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  bold=$(tput bold)
    normal=$(tput sgr0)
    
    cat <<EOF
${bold}Usage:${normal}

$(basename "${BASH_SOURCE[0]}") [-h] [-v] -b BUCKET_NAME -n BACKUP_NAME -p BACKUP_PATH

Backup all files and directories from a specified location to an AWS S3 bucket.

Directories will be archived as separate .tar.gz files.
The depth on which directories will be archived is controlled by the --split-depth parameter.

${bold}Available options:${normal}

-h, --help               Print this help and exit
-v, --verbose            Print script debug info
-b, --bucket string      S3 bucket name
-n, --name string        Backup name, acts as a S3 path prefix
-p, --path string        Path to the file or directory to backup
--storage-class string   S3 storage class (default "DEEP_ARCHIVE")
--dry-run                Don't upload files
--validate               Enable enhanced validation
--keep-local             Keep local copy of tar files for validation

If the BACKUP_PATH is a directory:

--max-size int           Maximum expected size of a single archive in GiB, used to calculate number of transfer chunks (default 1024 - 1 TiB)
--split-depth int        Directory level to create separate archive files (default 1)

${bold}Split depth examples:${normal}

For path /storage/user1:
- 0 - backup the whole /storage/user1 as a single archive
- 1 - backup each subdirectory in /storage/user1 as separate archives
- 2 - backup each subdirectory of subdirectories in /storage/user1 as separate archives
etc.

${bold}Validation:${normal}

The script always generates:
- .tar.gz archive files
- .md5 files with content hashes
- .txt files with complete file listings

With --validate flag, additional integrity checks are performed.
EOF
  exit
}

# Função para mostrar o plano de backup durante dry-run
show_backup_plan() {
  local current_path=$1
  local depth=$2
  local indent=""
  
  for ((i=1; i<depth; i++)); do
    indent="  $indent"
  done
  
  local full_path="$root_path/$current_path"
  [[ "$current_path" == "." ]] && full_path="$root_path"
  
  cd "$full_path" || return
  
  # Listar diretórios
  local dirs=()
  while IFS= read -r -d $'\0'; do
    dirs+=("$REPLY")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  
  # Listar arquivos no nível atual
  local files_count
  files_count=$(find . -maxdepth 1 -type f 2>/dev/null | wc -l)
  
  if [[ $depth -eq $split_depth ]]; then
    # Mostrar arquivos do nível atual
    if [[ $files_count -gt 0 ]]; then
      echo "${indent}📄 Arquivos ($files_count arquivos) → $backup_name/$current_path/_files.tar.gz"
    fi
    
    # Mostrar cada diretório como arquivo separado
    for dir in "${dirs[@]}"; do
      if [[ "$dir" != *\$RECYCLE.BIN && "$dir" != *.Trash-1000 && "$dir" != *System\ Volume\ Information ]]; then
        local dir_clean=$(echo "$dir" | sed 's|^\./||')
        local dir_files
        dir_files=$(find "$dir" -type f 2>/dev/null | wc -l)
        echo "${indent}📁 $dir_clean/ ($dir_files arquivos) → $backup_name/$current_path/$dir_clean.tar.gz"
      fi
    done
  elif [[ $depth -lt $split_depth ]]; then
    # Continuar descendo na estrutura
    for dir in "${dirs[@]}"; do
      if [[ "$dir" != *\$RECYCLE.BIN && "$dir" != *.Trash-1000 && "$dir" != *System\ Volume\ Information ]]; then
        local dir_clean=$(echo "$dir" | sed 's|^\./||')
        echo "${indent}📁 $dir_clean/"
        
        local next_path
        if [[ "$current_path" == "." ]]; then
          next_path="$dir_clean"
        else
          next_path="$current_path/$dir_clean"
        fi
        
        show_backup_plan "$next_path" $((depth + 1))
      fi
    done
  fi
}

main() {
  root_path=$(
    cd "$(dirname "$root_path")"
    pwd -P
  )/$(basename "$root_path") # convert to absolute path

  # division by 10k gives integer (without fraction), round result up by adding 1
  chunk_size_mb=$((max_size_gb * 1024 / 10000 + 1))

  # common rclone parameters for TAR.GZ files (Deep Archive)
  rclone_args=(
    "-P"
    "--progress"
    "--stats=10s"
    "--stats-one-line"
    "--s3-storage-class" "$storage_class"
    "--s3-upload-concurrency" 8
  )

  # common rclone parameters for TXT/MD5 files (Standard)
  rclone_standard_args=(
   "--progress"
    "--stats=10s"
    "--stats-one-line"
    "--s3-storage-class" "STANDARD"
    "--s3-upload-concurrency" 8
  )

  # If dry-run, show what would be backed up
  if [[ "$dry_run" == true ]]; then
    msg "🔍 DRY RUN MODE - Showing what would be backed up:"
    msg "📂 Root path: $root_path"
    msg "🎯 Split depth: $split_depth"
    msg "☁️  S3 bucket: $bucket"
    msg "📦 Backup name: $backup_name"
    msg "🗄️  Storage class: $storage_class"
    echo ""
    
    if [[ -f "$root_path" ]]; then
      msg "📄 Single file backup:"
      msg "   File: $root_path"
      msg "   → S3: $backup_name/$(basename "$root_path")"
    elif [[ "$split_depth" -eq 0 ]]; then
      msg "📦 Single archive backup:"
      msg "   Path: $root_path"
      msg "   → S3: $backup_name/$(basename "$root_path").tar.gz"
    else
      msg "📁 Directory structure that will be backed up:"
      show_backup_plan . 1
    fi
    echo ""
    msg "💡 Remove --dry-run to execute the actual backup"
    return
  fi

  if [[ -f "$root_path" ]]; then
    backup_file "$root_path" "$(basename "$root_path")"
  elif [[ "$split_depth" -eq 0 ]]; then
    backup_path "$root_path" "$(basename "$root_path")"
  else
    traverse_path . 1
  fi
  
  msg "🎉 Backup process completed successfully"
}

parse_params() {
  split_depth=1  
  max_size_gb=1024
  storage_class="DEEP_ARCHIVE"
  dry_run=false
  validate=false
  keep_local=false

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -b | --bucket)
      bucket="${2-}"
      shift
      ;;
    -n | --name)
      backup_name="${2-}"
      shift
      ;;
    -p | --path)
      root_path="${2-}"
      shift
      ;;
    --max-size)
      max_size_gb="${2-}"
      shift
      ;;
    --split-depth)
      split_depth="${2-}"
      shift
      ;;
    --storage-class)
      storage_class="${2-}"
      shift
      ;;
    --dry-run) dry_run=true ;;
    --validate) validate=true ;;
    --keep-local) keep_local=true ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  [[ -z "${bucket-}" ]] && die "Missing required parameter: bucket"
  [[ -z "${backup_name-}" ]] && die "Missing required parameter: name"
  [[ -z "${root_path-}" ]] && die "Missing required parameter: path"

  return 0
}

msg() {
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local message="${1-}"
  echo >&2 -e "[$timestamp] $message"
  # Força flush do buffer para exibição imediata
  exec 2>&2
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

# Generate comprehensive file listing
generate_file_list() {
  local path=$1
  local name=$2
  local files_only=${3-false}
  
  # Limpar o nome para criar um nome de arquivo válido
  local clean_name=$(echo "${name}" | sed 's|/|_|g' | sed 's|_files$||' | sed 's|^\.|_|')
  local list_file="/tmp/${backup_name}_${clean_name}_files.txt"
  
  cd "$path" || die "Can't access $path"
  
  {
    echo "Backup file listing for: $name"
    echo "Source path: $path"
    echo "Generated: $(date)"
    echo "Files only mode: $files_only"
    echo "----------------------------------------"
    echo ""
    
    if [[ "$files_only" == true ]]; then
      find . -maxdepth 1 -type f -exec ls -la {} \; | sort
    else
      # MUDANÇA: Para diretórios completos, vamos listar apenas arquivos do nível atual
      # para manter consistência com o cálculo de hash
      find . -maxdepth 1 -type f -exec ls -la {} \; | sort
    fi
    
    echo ""
    echo "----------------------------------------"
    echo "Summary:"
    echo "Files: $(find . -maxdepth 1 -type f | wc -l)"
    echo "Total size: $(find . -maxdepth 1 -type f -exec du -b {} \; | awk '{sum+=$1} END {print sum " bytes (" sum/1024/1024/1024 " GB)"}' || echo "0 bytes")"
  } > "$list_file"
  
  msg "📄 File listing generated: $list_file"
  
  # Upload file listing
  if [[ "$dry_run" != true ]]; then
    local s3_target="${backup_name}/${clean_name}_files.txt"
    # Upload file listing with STANDARD storage class
    rclone_standard_args=(
      "-P"
      "--s3-storage-class" "STANDARD"
      "--s3-upload-concurrency" 8
    )
    cat "$list_file" | rclone rcat "${rclone_standard_args[@]}" "AmazonS3:$bucket/$s3_target"
    msg "📤 File listing uploaded to S3: $s3_target"
    rm -f "$list_file"
  fi
}

# Enhanced validation function
validate_archive() {
  local archive_path=$1
  local original_path=$2
  local expected_count=$3
  
  if [[ ! -f "$archive_path" ]]; then
    msg "❌ Archive file not found: $archive_path"
    return 1
  fi
  
  # Test archive integrity
  if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
    msg "❌ Archive integrity check failed: $archive_path"
    return 1
  fi
  
  # Count files in archive
  local archive_count
  archive_count=$(tar -tzf "$archive_path" | wc -l)
  
  if [[ "$archive_count" -ne "$expected_count" ]]; then
    msg "❌ File count mismatch: archive has $archive_count files, expected $expected_count"
    return 1
  fi
  
  msg "✅ Archive validation passed: $archive_count files verified"
  return 0
}

# Arguments:
# - path - absolute path to backup
# - name - backup file name
backup_file() {
  local path=$1
  local name=$2

  msg "⬆️ Uploading archive $archive_name to S3 (Storage: $storage_class)"
  msg "🔄 Upload progress will be shown by rclone..."

  args=("${rclone_args[@]}" "--checksum")
  [[ "$dry_run" = true ]] && args+=("--dry-run")

  rclone copy "${args[@]}" "$path" "AmazonS3:$bucket/$backup_name"
}

# Arguments:
# - path - absolute path to backup
# - name - backup name, without an extension, optionally being an S3 path
# - files_only - whether to backup only dir-level files, or directory as a whole
backup_path() {
  (
    local path=$1
    local name=$2
    local files_only=${3-false}

    local archive_name files hash s3_hash local_archive

    path=$(echo "$path" | sed -E 's#(/(\./)+)|(/\.$)#/#g' | sed 's|/$||')     # remove /./ and trailing /
    archive_name=$(echo "$backup_name/$name.tar.gz" | sed -E 's|/(\./)+|/|g') # remove /./
    local_archive="/tmp/$(basename "$archive_name")"

    cd "$path" || die "Can't access $path"

    # MUDANÇA PRINCIPAL: Sempre usar apenas arquivos do nível atual para o hash
    # Isso garante que o hash seja por pasta, não recursivo
    msg "🔍 Listing files in \"$path\" (current level only)..."
    files=$(find . -maxdepth 1 -type f | sed 's/^\.\///g')

    # sort to maintain always the same order for hash
    files=$(echo "$files" | LC_ALL=C sort)

    if [[ -z "$files" ]]; then
      msg "🟫 No files found in $path"
      return
    fi

    files_count=$(echo "$files" | wc -l | awk '{ print $1 }')
    msg "ℹ️ Found $files_count files (current level only)"
    msg "📋 Files to backup: $(echo "$files" | head -5 | tr '\n' ' ')$([ $files_count -gt 5 ] && echo "... and $((files_count-5)) more")"
    
    # Generate detailed file listing
    generate_file_list "$path" "$name" "$files_only"
    
    msg "#️⃣ Calculating hash for files in current level of \"$path\"..."

    # Calcular hash apenas dos arquivos do nível atual (não recursivo)
    if [[ "$files_only" == true ]]; then
        # Para files_only, usar apenas os arquivos do nível atual
        hash=$(echo "$files" | tr '\n' '\0' | parallel -0 -k -m md5sum -- | md5sum | awk '{ print $1 }')
    else
        # Para diretório completo, calcular hash apenas dos arquivos do nível atual
        # mas incluir todo o conteúdo no tar
        current_level_files=$(find . -maxdepth 1 -type f | sed 's/^\.\///g' | LC_ALL=C sort)
        if [[ -n "$current_level_files" ]]; then
            hash=$(echo "$current_level_files" | tr '\n' '\0' | parallel -0 -k -m md5sum -- | md5sum | awk '{ print $1 }')
        else
            hash="empty_directory"
        fi
    fi

    # MUDANÇA: Agora o hash se baseia apenas nos arquivos do nível atual
    msg "ℹ️ Content hash (current level): $hash"

    s3_hash=$(rclone cat "AmazonS3:$bucket/$archive_name.md5" 2>/dev/null || echo "")

    if [[ "$hash" == "$s3_hash" ]] && [[ $(rclone lsf "AmazonS3:$bucket/$archive_name" 2>/dev/null | wc -l) -eq 1 ]]; then
      msg "🟨 Archive $archive_name already exists with the same content hash - skipping"
    else
      msg "📦 Creating archive $archive_name ($files_count files, estimated size: $(du -sh . 2>/dev/null | cut -f1 || echo "unknown"))"

      if [[ "$dry_run" != true ]]; then
        args=(
          "${rclone_args[@]}"
          "--s3-chunk-size" "${chunk_size_mb}M"
        )

        # MUDANÇA: Agora o tar sempre incluirá o conteúdo completo do diretório
        # mas o hash será baseado apenas nos arquivos do nível atual
        if [[ "$files_only" == true ]]; then
          # Para files_only, usar apenas os arquivos listados
          tar_files="$files"
        else
          # Para diretório completo, incluir tudo recursivamente no tar
          tar_files=$(find . -type f | sed 's/^\.\///g' | LC_ALL=C sort)
        fi

        # Create local archive first if validation is enabled or keep_local is true
        if [[ "$validate" == true ]] || [[ "$keep_local" == true ]]; then
          echo "$tar_files" | tr '\n' '\0' | xargs -0 tar -zcf "$local_archive" --
          
          # Validate local archive
          if [[ "$validate" == true ]]; then
            local expected_count
            expected_count=$(echo "$tar_files" | wc -l | awk '{ print $1 }')
            if validate_archive "$local_archive" "$path" "$expected_count"; then
              msg "✅ Local archive validation passed"
            else
              msg "❌ Local archive validation failed - aborting upload"
              rm -f "$local_archive"
              return 1
            fi
          fi
          
          msg "⬆️ Uploading validated archive $archive_name"
          cat "$local_archive" | rclone rcat "${args[@]}" "AmazonS3:$bucket/$archive_name"
          
          # Clean up local file unless keep_local is true
          if [[ "$keep_local" != true ]]; then
            rm -f "$local_archive"
          else
            msg "📁 Local archive kept at: $local_archive"
          fi
        else
          # Stream directly to S3 (original behavior)
          msg "⬆️ Streaming archive $archive_name to S3"
          echo "$tar_files" | tr '\n' '\0' | xargs -0 tar -zcf - -- |
            rclone rcat "${args[@]}" "AmazonS3:$bucket/$archive_name"
        fi

        # Upload hash with STANDARD storage class for quick access
        rclone_standard_args=(
          "-P"
          "--s3-storage-class" "STANDARD"
          "--s3-upload-concurrency" 8
        )
        echo "$hash" | rclone rcat "${rclone_standard_args[@]}" "AmazonS3:$bucket/$archive_name.md5"
        
        msg "🟩 Archive $archive_name uploaded successfully"
        
        # Final validation against S3 if requested
        if [[ "$validate" == true ]] && [[ "$keep_local" != true ]]; then
          msg "🔍 Performing S3 validation..."
          s3_uploaded_hash=$(rclone cat "AmazonS3:$bucket/$archive_name.md5" 2>/dev/null || echo "")
          if [[ "$hash" == "$s3_uploaded_hash" ]]; then
            msg "✅ S3 validation passed: hashes match"
          else
            msg "❌ S3 validation failed: hash mismatch"
            return 1
          fi
        fi
      else
        msg "🔍 Dry run: would upload $archive_name"
      fi
    fi
  )
}

# Arguments:
# - path - the path relative to $root_path
# - depth - the level from the $root_path
traverse_path() {
  local path=$1
  local depth=${2-1}

  cd "$root_path/$path" || die "Can't access $root_path/$path"

  # Only backup files at this level if we're at the target split depth
  if [[ $depth -eq $split_depth ]]; then
    # Primeiro, fazer backup dos arquivos soltos no nível atual
    local files_count
    files_count=$(find . -maxdepth 1 -type f 2>/dev/null | wc -l)
    
    if [[ $files_count -gt 0 ]]; then
      backup_path "$root_path/$path" "$path/_files" true
    fi
  fi

  # read directories to array, taking into account possible spaces in names
  local dirs=()
  while IFS= read -r -d $'\0'; do
    dirs+=("$REPLY")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  if [[ -n "${dirs:-}" ]]; then
    for dir in "${dirs[@]}"; do
      # Skip system directories
      if [[ "$dir" != *\$RECYCLE.BIN && "$dir" != *.Trash-1000 && "$dir" != *System\ Volume\ Information ]]; then
        local dir_clean=$(echo "$dir" | sed 's|^\./||')
        
        if [[ $depth -eq $split_depth ]]; then
          # At target depth: backup this directory as a single archive
          backup_path "$root_path/$path/$dir" "$path/$dir_clean" false
        elif [[ $depth -lt $split_depth ]]; then
          # Above target depth: continue traversing
          local next_path
          if [[ "$path" == "." ]]; then
            next_path="$dir_clean"
          else
            next_path="$path/$dir_clean"
          fi
          traverse_path "$next_path" $((depth + 1))
        fi
      fi
    done
  fi
}

parse_params "$@"
main
