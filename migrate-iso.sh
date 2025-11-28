#!/bin/bash

# =============================================================================
# Proxmox ISO Migration Tool
# Copyright (c) 2025 Carlos Vargas [Carlos Vargas / Bezalel Digital]
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# For commercial licensing options, contact: [info at carlos vargas dot com]
# =============================================================================

set -e

echo "========================================"
echo "  Proxmox ISO Migration Tool"
echo "========================================"
echo

# Function to get storage paths that support ISO content
get_iso_storages() {
    local storages=()
    local current_storage=""
    local current_path=""
    local has_iso_content=false
    
    while IFS= read -r line; do
        # Check for storage definition (e.g., "dir: local" or "nfs: nas-storage")
        if [[ $line =~ ^[a-z]+:\ (.+)$ ]]; then
            # Save previous storage if it had ISO content
            if [[ -n "$current_storage" && "$has_iso_content" == true && -n "$current_path" ]]; then
                storages+=("$current_storage|$current_path")
            fi
            current_storage="${BASH_REMATCH[1]}"
            current_path=""
            has_iso_content=false
        fi
        
        # Check for path
        if [[ $line =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
        fi
        
        # Check for content that includes "iso"
        if [[ $line =~ ^[[:space:]]+content[[:space:]]+(.+)$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == *"iso"* ]]; then
                has_iso_content=true
            fi
        fi
    done < /etc/pve/storage.cfg
    
    # Don't forget the last storage
    if [[ -n "$current_storage" && "$has_iso_content" == true && -n "$current_path" ]]; then
        storages+=("$current_storage|$current_path")
    fi
    
    printf '%s\n' "${storages[@]}"
}

# Get all storages with ISO support
echo "Scanning storage configuration..."
mapfile -t STORAGES < <(get_iso_storages)

if [[ ${#STORAGES[@]} -lt 2 ]]; then
    echo "Error: Need at least 2 storage locations with ISO support."
    echo "Found: ${#STORAGES[@]}"
    exit 1
fi

echo
echo "Found ${#STORAGES[@]} storage location(s) with ISO support:"
echo

# Display source selection
echo "========================================"
echo "  SELECT SOURCE STORAGE"
echo "========================================"
for i in "${!STORAGES[@]}"; do
    IFS='|' read -r name path <<< "${STORAGES[$i]}"
    iso_path="$path/template/iso"
    if [[ -d "$iso_path" ]]; then
        iso_count=$(find "$iso_path" -maxdepth 1 -name "*.iso" 2>/dev/null | wc -l)
    else
        iso_count=0
    fi
    echo "  $((i+1))) $name"
    echo "      Path: $path"
    echo "      ISOs: $iso_count"
    echo
done

read -p "Select source storage [1-${#STORAGES[@]}]: " source_choice

if [[ ! "$source_choice" =~ ^[0-9]+$ ]] || [[ "$source_choice" -lt 1 ]] || [[ "$source_choice" -gt ${#STORAGES[@]} ]]; then
    echo "Invalid selection."
    exit 1
fi

source_index=$((source_choice - 1))
IFS='|' read -r SOURCE_NAME SOURCE_PATH <<< "${STORAGES[$source_index]}"
SOURCE_ISO_PATH="$SOURCE_PATH/template/iso"

echo
echo "Selected source: $SOURCE_NAME ($SOURCE_ISO_PATH)"
echo

# List ISOs in source
echo "========================================"
echo "  ISOs IN SOURCE STORAGE"
echo "========================================"
if [[ ! -d "$SOURCE_ISO_PATH" ]]; then
    echo "ISO directory does not exist: $SOURCE_ISO_PATH"
    exit 1
fi

mapfile -t ISO_FILES < <(find "$SOURCE_ISO_PATH" -maxdepth 1 -name "*.iso" -printf "%f\n" 2>/dev/null | sort)

if [[ ${#ISO_FILES[@]} -eq 0 ]]; then
    echo "No ISO files found in source storage."
    exit 0
fi

echo
total_size=0
for iso in "${ISO_FILES[@]}"; do
    size=$(stat -c%s "$SOURCE_ISO_PATH/$iso" 2>/dev/null || echo 0)
    size_human=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")
    total_size=$((total_size + size))
    echo "  - $iso ($size_human)"
done
total_size_human=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "${total_size} bytes")
echo
echo "Total: ${#ISO_FILES[@]} ISO(s), $total_size_human"
echo

# Display destination selection (excluding source)
echo "========================================"
echo "  SELECT DESTINATION STORAGE"
echo "========================================"
dest_options=()
for i in "${!STORAGES[@]}"; do
    if [[ $i -ne $source_index ]]; then
        dest_options+=("$i")
        IFS='|' read -r name path <<< "${STORAGES[$i]}"
        echo "  ${#dest_options[@]}) $name"
        echo "      Path: $path"
        echo
    fi
done

if [[ ${#dest_options[@]} -eq 0 ]]; then
    echo "No other storage locations available."
    exit 1
fi

read -p "Select destination storage [1-${#dest_options[@]}]: " dest_choice

if [[ ! "$dest_choice" =~ ^[0-9]+$ ]] || [[ "$dest_choice" -lt 1 ]] || [[ "$dest_choice" -gt ${#dest_options[@]} ]]; then
    echo "Invalid selection."
    exit 1
fi

dest_index=${dest_options[$((dest_choice - 1))]}
IFS='|' read -r DEST_NAME DEST_PATH <<< "${STORAGES[$dest_index]}"
DEST_ISO_PATH="$DEST_PATH/template/iso"

echo
echo "Selected destination: $DEST_NAME ($DEST_ISO_PATH)"
echo

# Check/create destination directory
if [[ ! -d "$DEST_ISO_PATH" ]]; then
    echo "Creating destination ISO directory..."
    mkdir -p "$DEST_ISO_PATH"
fi

# Check available space
available_space=$(df -B1 "$DEST_PATH" | awk 'NR==2 {print $4}')
available_space_human=$(numfmt --to=iec-i --suffix=B "$available_space" 2>/dev/null || echo "${available_space} bytes")

echo "========================================"
echo "  TRANSFER SUMMARY"
echo "========================================"
echo
echo "  Source:      $SOURCE_NAME"
echo "  Destination: $DEST_NAME"
echo "  Files:       ${#ISO_FILES[@]} ISO(s)"
echo "  Total size:  $total_size_human"
echo "  Available:   $available_space_human"
echo

if [[ $total_size -gt $available_space ]]; then
    echo "ERROR: Not enough space on destination!"
    echo "Required: $total_size_human, Available: $available_space_human"
    exit 1
fi

# Confirm
echo "========================================"
read -p "Proceed with copy? [y/N]: " confirm
echo

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Copy files with progress
echo "========================================"
echo "  COPYING FILES"
echo "========================================"
echo

copied=0
failed=0

for iso in "${ISO_FILES[@]}"; do
    src_file="$SOURCE_ISO_PATH/$iso"
    dst_file="$DEST_ISO_PATH/$iso"
    
    echo "Copying: $iso"
    
    if [[ -f "$dst_file" ]]; then
        echo "  WARNING: File already exists at destination, skipping."
        continue
    fi
    
    if rsync -ah --progress "$src_file" "$dst_file"; then
        echo "  Done."
        ((copied++))
    else
        echo "  FAILED!"
        ((failed++))
    fi
    echo
done

# Summary
echo "========================================"
echo "  COMPLETE"
echo "========================================"
echo
echo "  Copied: $copied"
echo "  Skipped/Failed: $failed"
echo
echo "ISOs are now available in storage: $DEST_NAME"
