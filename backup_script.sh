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

main() {
  root_path=$(
    cd "$(dirname "$root_path")"
    pwd -P
  )/$(basename "$root_path") # convert to absolute path

  # division by 10k gives integer (without fraction), round result up by adding 1
  chunk_size_mb=$((max_size_gb * 1024 / 10000 + 1))

  # common rclone parameters
  rclone_args=(
    "-P"
    "--s3-storage-class" "$storage_class"
    "--s3-upload-concurrency" 8
  )

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
  split_depth=1  # Mudança: padrão agora é 1 (mais útil)
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
  echo >&2 -e "$(date +"%Y-%m-%d %H:%M:%S") ${1-}"
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
  
  local list_file="/tmp/${backup_name}_${name//\//_}_files.txt"
  
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
      find . -type f -exec ls -la {} \; | sort
    fi
    
    echo ""
    echo "----------------------------------------"
    echo "Summary:"
    if [[ "$files_only" == true ]]; then
      echo "Files: $(find . -maxdepth 1 -type f | wc -l)"
      echo "Total size: $(find . -maxdepth 1 -type f -exec du -b {} \; | awk '{sum+=$1} END {print sum " bytes (" sum/1024/1024/1024 " GB)"}' || echo "0 bytes")"
    else
      echo "Files: $(find . -type f | wc -l)"
      echo "Directories: $(find . -type d | wc -l)"
      echo "Total size: $(du -sb . | cut -f1) bytes ($(du -sh . | cut -f1))"
    fi
  } > "$list_file"
  
  msg "📄 File listing generated: $list_file"
  
  # Upload file listing
  if [[ "$dry_run" != true ]]; then
    local s3_list_path="${backup_name}/${name}.txt"
    rclone copy "${rclone_args[@]}" "$list_file" "AmazonS3:$bucket/$(dirname "$s3_list_path")/" 
    msg "📤 File listing uploaded to S3: $s3_list_path"
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

  msg "⬆️ Uploading file $name"

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

    if [[ "$files_only" == true ]]; then
      msg "🔍 Listing files in \"$path\"..."
      files=$(find . -maxdepth 1 -type f | sed 's/^\.\///g')
    else
      msg "🔍 Listing all files under \"$path\"..."
      files=$(find . -type f | sed 's/^\.\///g')
    fi

    # sort to maintain always the same order for hash
    files=$(echo "$files" | LC_ALL=C sort)

    if [[ -z "$files" ]]; then
      msg "🟫 No files found in $path"
      return
    fi

    files_count=$(echo "$files" | wc -l | awk '{ print $1 }')
    msg "ℹ️ Found $files_count files"
    
    # Generate detailed file listing
    generate_file_list "$path" "$name" "$files_only"
    
    if [[ "$files_only" == true ]]; then
        msg "#️⃣ Calculating hash for files in path \"$path\"..."
    else
        msg "#️⃣ Calculating hash for directory \"$path\"..."
    fi

    # replace newlines with zero byte to distinct between whitespaces in names and next files
    # "md5sum --" to signal start of file names in case file name starts with "-"
    hash=$(echo "$files" | tr '\n' '\0' | parallel -0 -k -m md5sum -- | md5sum | awk '{ print $1 }')
    msg "ℹ️ Content hash: $hash"

    s3_hash=$(rclone cat "AmazonS3:$bucket/$archive_name.md5" 2>/dev/null || echo "")

    if [[ "$hash" == "$s3_hash" ]] && [[ $(rclone lsf "AmazonS3:$bucket/$archive_name" 2>/dev/null | wc -l) -eq 1 ]]; then
      msg "🟨 Archive $archive_name already exists with the same content hash - skipping"
    else
      msg "📦 Creating archive $archive_name"

      if [[ "$dry_run" != true ]]; then
        args=(
          "${rclone_args[@]}"
          "--s3-chunk-size" "${chunk_size_mb}M"
        )

        # Create local archive first if validation is enabled or keep_local is true
        if [[ "$validate" == true ]] || [[ "$keep_local" == true ]]; then
          echo "$files" | tr '\n' '\0' | xargs -0 tar -zcf "$local_archive" --
          
          # Validate local archive
          if [[ "$validate" == true ]]; then
            if validate_archive "$local_archive" "$path" "$files_count"; then
              msg "✅ Local archive validation passed"
            else
              msg "❌ Local archive validation failed - aborting upload"
              rm -f "$local_archive"
              return 1
            fi
          fi
          
          # Upload from local file
          msg "⬆️ Uploading validated archive $archive_name"
          rclone copy "${args[@]}" "$local_archive" "AmazonS3:$bucket/$(dirname "$archive_name")/"
          
          # Clean up local file unless keep_local is true
          if [[ "$keep_local" != true ]]; then
            rm -f "$local_archive"
          else
            msg "📁 Local archive kept at: $local_archive"
          fi
        else
          # Stream directly to S3 (original behavior)
          msg "⬆️ Streaming archive $archive_name to S3"
          echo "$files" | tr '\n' '\0' | xargs -0 tar -zcf - -- |
            rclone rcat "${args[@]}" "AmazonS3:$bucket/$archive_name"
        fi

        # Upload hash and file list
        echo "$hash" | rclone rcat "AmazonS3:$bucket/$archive_name.md5"
        
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
    backup_path "$root_path/$path" "$path/_files" true
  fi

  # read directories to array, taking into account possible spaces in names
  local dirs=()
  while IFS= read -r -d $'\0'; do
    dirs+=("$REPLY")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -n "${dirs:-}" ]]; then
    for dir in "${dirs[@]}"; do
      # Skip system directories
      if [[ "$dir" != *\$RECYCLE.BIN && "$dir" != *.Trash-1000 && "$dir" != *System\ Volume\ Information ]]; then
        if [[ $depth -eq $split_depth ]]; then
          # At target depth: backup this directory as a single archive
          backup_path "$root_path/$path/$dir" "$path/$dir" false
        elif [[ $depth -lt $split_depth ]]; then
          # Above target depth: continue traversing
          traverse_path "$path/$dir" $((depth + 1))
        fi
      fi
    done
  fi
}

parse_params "$@"
main
