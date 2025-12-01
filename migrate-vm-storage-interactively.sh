#!/bin/bash

# Proxmox VM Storage Migration Script - Interactive Version
# Provides menu-driven selection for VM and storage migration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Clear screen and show header
show_header() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         Proxmox VM Storage Migration Tool                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get human readable size from KB
human_size_kb() {
    local size_kb=$1
    
    # Handle empty or non-numeric
    if [[ -z "$size_kb" ]] || [[ ! "$size_kb" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return
    fi
    
    if [[ $size_kb -ge 1073741824 ]]; then
        awk "BEGIN {printf \"%.1f TB\", $size_kb/1073741824}"
    elif [[ $size_kb -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.1f GB\", $size_kb/1048576}"
    elif [[ $size_kb -ge 1024 ]]; then
        awk "BEGIN {printf \"%.1f MB\", $size_kb/1024}"
    else
        echo "${size_kb} KB"
    fi
}

# Get VM status with color
get_status_colored() {
    local status=$1
    case $status in
        running)  echo -e "${GREEN}●${NC} Running" ;;
        stopped)  echo -e "${RED}●${NC} Stopped" ;;
        paused)   echo -e "${YELLOW}●${NC} Paused" ;;
        *)        echo -e "${DIM}●${NC} $status" ;;
    esac
}

# Extract storage name from a disk config line
# Input: "scsi0: cephvm1:vm-104-disk-0,size=167424M"
# Output: "cephvm1"
extract_storage_name() {
    local line="$1"
    # Remove device prefix (e.g., "scsi0: "), then get everything before first ":"
    echo "$line" | sed 's/^[^:]*:[[:space:]]*//' | cut -d: -f1
}

# Extract device name from a disk config line
# Input: "scsi0: cephvm1:vm-104-disk-0,size=167424M"
# Output: "scsi0"
extract_device_name() {
    local line="$1"
    echo "$line" | cut -d: -f1
}

# Get all VMs
declare -a VM_IDS

enumerate_vms() {
    VM_IDS=()
    
    echo -e "${DIM}Scanning VMs...${NC}"
    
    for conf in /etc/pve/qemu-server/*.conf; do
        if [[ -f "$conf" ]]; then
            local vmid=$(basename "$conf" .conf)
            VM_IDS+=("$vmid")
        fi
    done
    
    # Sort VM IDs numerically
    IFS=$'\n' VM_IDS=($(sort -n <<<"${VM_IDS[*]}")); unset IFS
}

# Get all disk lines for a VM
get_vm_disks() {
    local vmid=$1
    qm config "$vmid" 2>/dev/null | grep -E "^(scsi|virtio|ide|sata|efidisk|tpmstate)[0-9]+:"
}

# Get unique storages used by a VM
get_vm_storages() {
    local vmid=$1
    local storages=()
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local storage=$(extract_storage_name "$line")
        [[ -n "$storage" ]] && storages+=("$storage")
    done < <(get_vm_disks "$vmid")
    
    # Return unique sorted list
    printf '%s\n' "${storages[@]}" | sort -u
}

# Get disks on a specific storage for a VM
get_disks_on_storage() {
    local vmid=$1
    local target_storage=$2
    local devices=()
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local storage=$(extract_storage_name "$line")
        if [[ "$storage" == "$target_storage" ]]; then
            local device=$(extract_device_name "$line")
            devices+=("$device")
        fi
    done < <(get_vm_disks "$vmid")
    
    echo "${devices[@]}"
}

# Display VM selection menu
show_vm_menu() {
    show_header
    echo -e "${BOLD}Step 1: Select a VM to migrate${NC}\n"
    
    printf "${BOLD}%-5s %-8s %-25s %-12s %-10s %-6s %-20s${NC}\n" "#" "VMID" "NAME" "STATUS" "MEMORY" "CPUS" "STORAGE(S)"
    echo "────────────────────────────────────────────────────────────────────────────────────────────"
    
    declare -g -A VM_MENU_MAP
    local index=1
    
    for vmid in "${VM_IDS[@]}"; do
        local name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
        local status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        local memory=$(qm config "$vmid" 2>/dev/null | grep "^memory:" | awk '{print $2}')
        local cores=$(qm config "$vmid" 2>/dev/null | grep "^cores:" | awk '{print $2}')
        local sockets=$(qm config "$vmid" 2>/dev/null | grep "^sockets:" | awk '{print $2}')
        
        name=${name:-"(unnamed)"}
        memory=${memory:-"N/A"}
        sockets=${sockets:-1}
        cores=${cores:-1}
        local total_cores=$((sockets * cores))
        
        # Get all storages for this VM
        local vm_storages=$(get_vm_storages "$vmid" | tr '\n' ',' | sed 's/,$//')
        vm_storages=${vm_storages:-"N/A"}
        
        # Format memory
        if [[ "$memory" != "N/A" ]]; then
            if [[ $memory -ge 1024 ]]; then
                memory="$(awk "BEGIN {printf \"%.1f\", $memory/1024}") GB"
            else
                memory="${memory} MB"
            fi
        fi
        
        local status_display=$(get_status_colored "$status")
        
        printf "${CYAN}%-5s${NC} %-8s %-25s %-12b %-10s %-6s %-20s\n" \
            "[$index]" "$vmid" "${name:0:24}" "$status_display" "$memory" "$total_cores" "${vm_storages:0:19}"
        
        VM_MENU_MAP[$index]=$vmid
        ((index++))
    done
    
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────────────"
    echo ""
    echo -e "${DIM}Enter number to select, or 'q' to quit${NC}"
    echo ""
}

# Show detailed VM info after selection
show_vm_details() {
    local vmid=$1
    
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  VM Details: $vmid${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
    local status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    local memory=$(qm config "$vmid" 2>/dev/null | grep "^memory:" | awk '{print $2}')
    local cores=$(qm config "$vmid" 2>/dev/null | grep "^cores:" | awk '{print $2}')
    local sockets=$(qm config "$vmid" 2>/dev/null | grep "^sockets:" | awk '{print $2}')
    local cpu=$(qm config "$vmid" 2>/dev/null | grep "^cpu:" | awk '{print $2}')
    
    sockets=${sockets:-1}
    cores=${cores:-1}
    
    echo -e "  ${BOLD}Name:${NC}     ${name:-N/A}"
    echo -e "  ${BOLD}Status:${NC}   $(get_status_colored "$status")"
    echo -e "  ${BOLD}Memory:${NC}   ${memory:-N/A} MB"
    echo -e "  ${BOLD}CPU:${NC}      ${sockets} socket(s), ${cores} core(s) - ${cpu:-default}"
    echo ""
    
    echo -e "  ${BOLD}Disks:${NC}"
    echo ""
    
    local disks=$(get_vm_disks "$vmid")
    
    if [[ -z "$disks" ]]; then
        echo -e "    ${DIM}No disks found${NC}"
    else
        printf "    ${BOLD}%-12s %-20s %-30s %-12s${NC}\n" "DEVICE" "STORAGE" "VOLUME" "SIZE"
        echo "    ─────────────────────────────────────────────────────────────────────────"
        
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            
            local device=$(extract_device_name "$line")
            local storage=$(extract_storage_name "$line")
            
            # Extract volume (everything after storage:)
            local after_device=$(echo "$line" | sed 's/^[^:]*:[[:space:]]*//')
            local volume=$(echo "$after_device" | cut -d: -f2 | cut -d, -f1)
            
            # Extract size
            local size=$(echo "$line" | grep -oP 'size=\K[^,]+' || echo "N/A")
            
            printf "    %-12s ${YELLOW}%-20s${NC} %-30s %-12s\n" \
                "$device" "${storage:0:19}" "${volume:0:29}" "${size}"
                
        done <<< "$disks"
    fi
    
    echo ""
}

# Enumerate available storages
declare -a STORAGE_NAMES
declare -A STORAGE_DATA

enumerate_storages() {
    STORAGE_NAMES=()
    STORAGE_DATA=()
    
    while read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^Name ]] && continue
        
        local name=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local total=$(echo "$line" | awk '{print $4}')
        local used=$(echo "$line" | awk '{print $5}')
        local avail=$(echo "$line" | awk '{print $6}')
        local percent=$(echo "$line" | awk '{print $7}')
        
        [[ -z "$name" ]] && continue
        
        STORAGE_NAMES+=("$name")
        STORAGE_DATA["${name}_type"]="$type"
        STORAGE_DATA["${name}_status"]="$status"
        STORAGE_DATA["${name}_total"]="$total"
        STORAGE_DATA["${name}_used"]="$used"
        STORAGE_DATA["${name}_avail"]="$avail"
        STORAGE_DATA["${name}_percent"]="$percent"
        
    done < <(pvesm status 2>/dev/null)
    
    IFS=$'\n' STORAGE_NAMES=($(sort <<<"${STORAGE_NAMES[*]}")); unset IFS
}

# Get storage content types
get_storage_content() {
    local storage=$1
    cat /etc/pve/storage.cfg 2>/dev/null | grep -A 20 "^[a-z]*: $storage$" | grep "content " | head -1 | sed 's/.*content //'
}

# Show storage selection menu with numbers
show_storage_menu() {
    local source_storages="$1"
    
    echo ""
    echo -e "${BOLD}Step 2: Select destination storage${NC}\n"
    
    # Convert source storages to array for comparison
    IFS=$'\n' read -d '' -ra SOURCE_ARRAY <<< "$source_storages" || true
    
    printf "${BOLD}%-5s %-20s %-10s %-10s %-12s %-12s %-8s %-15s${NC}\n" \
        "#" "STORAGE" "TYPE" "STATUS" "TOTAL" "AVAILABLE" "USED%" "CONTENT"
    echo "───────────────────────────────────────────────────────────────────────────────────────────────"
    
    local index=1
    declare -g -A STORAGE_MENU_MAP
    declare -g -a AVAILABLE_STORAGES
    AVAILABLE_STORAGES=()
    
    for storage in "${STORAGE_NAMES[@]}"; do
        local type="${STORAGE_DATA["${storage}_type"]}"
        local status="${STORAGE_DATA["${storage}_status"]}"
        local total="${STORAGE_DATA["${storage}_total"]}"
        local avail="${STORAGE_DATA["${storage}_avail"]}"
        local percent="${STORAGE_DATA["${storage}_percent"]}"
        local content=$(get_storage_content "$storage")
        
        # Check if this is a source storage
        local is_source=false
        for src in "${SOURCE_ARRAY[@]}"; do
            if [[ "$storage" == "$src" ]]; then
                is_source=true
                break
            fi
        done
        
        # Skip inactive storage
        if [[ "$status" != "active" ]]; then
            continue
        fi
        
        # Check if storage supports images
        local supports_images=false
        if [[ "$content" == *"images"* ]]; then
            supports_images=true
        fi
        
        # Format sizes (pvesm reports in KB)
        local total_h=$(human_size_kb "$total")
        local avail_h=$(human_size_kb "$avail")
        
        # Mark source storage and non-image storage
        local marker=""
        local num_display=""
        local color="${NC}"
        
        if [[ "$is_source" == true ]]; then
            marker="${YELLOW}(source)${NC}"
            num_display="${DIM}[-]${NC}"
            color="${DIM}"
        elif [[ "$supports_images" == false ]]; then
            marker="${RED}(no images)${NC}"
            num_display="${DIM}[-]${NC}"
            color="${DIM}"
        else
            num_display="${CYAN}[$index]${NC}"
            STORAGE_MENU_MAP[$index]=$storage
            AVAILABLE_STORAGES+=("$storage")
            ((index++))
        fi
        
        printf "%-5b ${color}%-20s %-10s %-10s %-12s %-12s %-8s${NC} %-15s %b\n" \
            "$num_display" "${storage:0:19}" "${type:0:9}" "$status" "$total_h" "$avail_h" "${percent:-N/A}" "${content:0:14}" "$marker"
            
    done
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────────────────────────"
    echo ""
    
    if [[ ${#AVAILABLE_STORAGES[@]} -eq 0 ]]; then
        log_error "No valid destination storages available!"
        log_info "Make sure your destination storage has 'images' content type enabled."
        echo ""
        echo "To enable images on NFS storage, edit /etc/pve/storage.cfg:"
        echo "  content images,rootdir,vztmpl,iso,backup"
        echo ""
        return 1
    fi
    
    echo -e "${DIM}Enter number to select, 'b' to go back, 'q' to quit${NC}"
    echo ""
    return 0
}

# Perform the migration
perform_migration() {
    local vmid=$1
    local source_storage=$2
    local dest_storage=$3
    local offline=$4
    local disk_format=$5
    
    echo ""
    log_info "Starting migration of VM $vmid disks from $source_storage to $dest_storage"
    echo ""
    
    # Get disks on source storage
    local disks=$(get_disks_on_storage "$vmid" "$source_storage")
    
    if [[ -z "$disks" ]]; then
        log_warn "No disks found on $source_storage for VM $vmid"
        return 0
    fi
    
    local disk_count=$(echo "$disks" | wc -w)
    log_info "Found $disk_count disk(s) to migrate: $disks"
    
    # Check VM status
    local vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    local was_running=false
    
    if [[ "$vm_status" == "running" ]]; then
        was_running=true
        if [[ "$offline" == true ]]; then
            log_info "Stopping VM $vmid for offline migration..."
            qm shutdown "$vmid" --timeout 120 2>/dev/null || qm stop "$vmid"
            
            # Wait for VM to stop
            local wait_count=0
            while [[ $(qm status "$vmid" 2>/dev/null | awk '{print $2}') == "running" ]]; do
                sleep 2
                ((wait_count++))
                if [[ $wait_count -gt 30 ]]; then
                    log_warn "VM taking too long to stop, forcing..."
                    qm stop "$vmid"
                    sleep 5
                    break
                fi
            done
            log_success "VM stopped"
        else
            log_info "Performing online migration (VM will remain running)"
        fi
    fi
    
    echo ""
    
    # Migrate each disk
    local success_count=0
    local fail_count=0
    
    for disk in $disks; do
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log_info "Migrating $disk..."
        
        # Build command with optional format
        local cmd="qm move_disk $vmid $disk $dest_storage --delete"
        if [[ -n "$disk_format" ]]; then
            cmd="$cmd --format $disk_format"
        fi
        
        log_info "Running: $cmd"
        
        if eval "$cmd" 2>&1; then
            log_success "$disk migrated successfully"
            ((success_count++))
        else
            log_error "Failed to migrate $disk"
            ((fail_count++))
        fi
    done
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Restart VM if needed
    if [[ "$was_running" == true ]] && [[ "$offline" == true ]]; then
        log_info "Starting VM $vmid..."
        qm start "$vmid"
        log_success "VM started"
    fi
    
    # Summary
    echo ""
    echo -e "${BOLD}Migration Summary:${NC}"
    echo -e "  Successful: ${GREEN}$success_count${NC}"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "  Failed:     ${RED}$fail_count${NC}"
    fi
    echo ""
}

# Main interactive loop
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check if running on Proxmox
    if ! command -v qm &> /dev/null; then
        log_error "This script must be run on a Proxmox host"
        exit 1
    fi
    
    while true; do
        show_header
        enumerate_vms
        enumerate_storages
        show_vm_menu
        
        read -p "Select VM [1-${#VM_IDS[@]}]: " vm_choice
        
        # Handle quit
        if [[ "$vm_choice" == "q" ]] || [[ "$vm_choice" == "Q" ]]; then
            echo ""
            log_info "Exiting..."
            exit 0
        fi
        
        # Validate selection is a number and in range
        if ! [[ "$vm_choice" =~ ^[0-9]+$ ]] || [[ -z "${VM_MENU_MAP[$vm_choice]}" ]]; then
            log_error "Invalid selection: $vm_choice"
            read -p "Press Enter to continue..."
            continue
        fi
        
        SELECTED_VM="${VM_MENU_MAP[$vm_choice]}"
        
        # Show VM details
        show_header
        show_vm_details "$SELECTED_VM"
        
        # Get source storages for this VM
        SOURCE_STORAGES=$(get_vm_storages "$SELECTED_VM")
        
        if [[ -z "$SOURCE_STORAGES" ]]; then
            log_warn "This VM has no disk storages to migrate from"
            read -p "Press Enter to continue..."
            continue
        fi
        
        # Show storages and ask user to select source
        local storage_count=$(echo "$SOURCE_STORAGES" | wc -l)
        
        echo -e "${BOLD}Source storage(s) detected:${NC}"
        echo ""
        
        local idx=1
        declare -A SRC_STORAGE_MAP
        while IFS= read -r storage; do
            [[ -z "$storage" ]] && continue
            local disk_count=$(get_disks_on_storage "$SELECTED_VM" "$storage" | wc -w)
            echo -e "  ${CYAN}[$idx]${NC} $storage ($disk_count disk(s))"
            SRC_STORAGE_MAP[$idx]=$storage
            ((idx++))
        done <<< "$SOURCE_STORAGES"
        
        if [[ $storage_count -gt 1 ]]; then
            echo -e "  ${CYAN}[a]${NC} Migrate from ALL storages"
        fi
        echo ""
        
        SELECTED_SOURCE=""
        if [[ $storage_count -eq 1 ]]; then
            SELECTED_SOURCE="$SOURCE_STORAGES"
            log_info "Auto-selected source storage: $SELECTED_SOURCE"
        else
            read -p "Select source storage [1-$((idx-1))]: " src_choice
            
            if [[ "$src_choice" == "a" ]] || [[ "$src_choice" == "A" ]]; then
                SELECTED_SOURCE="__ALL__"
            elif [[ -n "${SRC_STORAGE_MAP[$src_choice]}" ]]; then
                SELECTED_SOURCE="${SRC_STORAGE_MAP[$src_choice]}"
            else
                log_error "Invalid selection"
                read -p "Press Enter to continue..."
                continue
            fi
        fi
        
        # For destination menu, only exclude the selected source storage (not all VM storages)
        local storages_to_exclude=""
        if [[ "$SELECTED_SOURCE" == "__ALL__" ]]; then
            # If migrating from all, exclude all source storages
            storages_to_exclude="$SOURCE_STORAGES"
        else
            # Only exclude the specific source storage we're migrating from
            storages_to_exclude="$SELECTED_SOURCE"
        fi
        
        # Show storage menu
        if ! show_storage_menu "$storages_to_exclude"; then
            read -p "Press Enter to continue..."
            continue
        fi
        
        read -p "Select destination storage [1-${#AVAILABLE_STORAGES[@]}]: " storage_choice
        
        # Handle navigation
        if [[ "$storage_choice" == "b" ]] || [[ "$storage_choice" == "B" ]]; then
            continue
        fi
        
        if [[ "$storage_choice" == "q" ]] || [[ "$storage_choice" == "Q" ]]; then
            echo ""
            log_info "Exiting..."
            exit 0
        fi
        
        # Validate storage selection
        if ! [[ "$storage_choice" =~ ^[0-9]+$ ]] || [[ -z "${STORAGE_MENU_MAP[$storage_choice]}" ]]; then
            log_error "Invalid selection: $storage_choice"
            read -p "Press Enter to continue..."
            continue
        fi
        
        SELECTED_DEST="${STORAGE_MENU_MAP[$storage_choice]}"
        
        # Check destination storage type for format options
        local dest_type="${STORAGE_DATA["${SELECTED_DEST}_type"]}"
        local disk_format=""
        
        # If destination is file-based storage (nfs, dir, cifs), offer format choice
        if [[ "$dest_type" == "nfs" ]] || [[ "$dest_type" == "dir" ]] || [[ "$dest_type" == "cifs" ]]; then
            echo ""
            echo -e "${BOLD}Disk Format Options:${NC}"
            echo ""
            echo "  [1] qcow2  - Recommended for NFS/file storage (supports snapshots)"
            echo "  [2] raw    - Better performance, larger files"
            echo "  [3] vmdk   - VMware compatible"
            echo ""
            read -p "Select disk format [1-3] (default: 1): " format_choice
            
            case $format_choice in
                2) disk_format="raw" ;;
                3) disk_format="vmdk" ;;
                *) disk_format="qcow2" ;;
            esac
            
            log_info "Using disk format: $disk_format"
        fi
        
        # Migration options
        echo ""
        echo -e "${BOLD}Migration Type:${NC}"
        echo ""
        echo "  [1] Online migration  - VM stays running (slower)"
        echo "  [2] Offline migration - VM will be stopped (faster, recommended)"
        echo ""
        read -p "Select migration type [1/2] (default: 2): " migration_type
        
        local offline=true
        if [[ "$migration_type" == "1" ]]; then
            offline=false
        fi
        
        # Confirmation
        echo ""
        echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  Migration Confirmation${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  VM:                ${CYAN}$SELECTED_VM${NC} ($(qm config "$SELECTED_VM" 2>/dev/null | grep "^name:" | awk '{print $2}'))"
        if [[ "$SELECTED_SOURCE" == "__ALL__" ]]; then
            echo -e "  Source Storage:    ${YELLOW}ALL${NC}"
            # Show what will be migrated
            echo -e "  Disks to migrate:"
            while IFS= read -r src; do
                [[ -z "$src" ]] && continue
                local src_disks=$(get_disks_on_storage "$SELECTED_VM" "$src")
                echo -e "    - From ${YELLOW}$src${NC}: $src_disks"
            done <<< "$SOURCE_STORAGES"
        else
            echo -e "  Source Storage:    ${YELLOW}$SELECTED_SOURCE${NC}"
            local migrate_disks=$(get_disks_on_storage "$SELECTED_VM" "$SELECTED_SOURCE")
            echo -e "  Disks to migrate:  $migrate_disks"
        fi
        echo -e "  Destination:       ${GREEN}$SELECTED_DEST${NC}"
        if [[ -n "$disk_format" ]]; then
            echo -e "  Disk Format:       ${GREEN}$disk_format${NC}"
        fi
        echo -e "  Migration Type:    $(if [[ "$offline" == true ]]; then echo "${GREEN}Offline${NC}"; else echo "${YELLOW}Online${NC}"; fi)"
        echo ""
        
        read -p "Proceed with migration? (y/N): " confirm
        
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Migration cancelled"
            read -p "Press Enter to continue..."
            continue
        fi
        
        # Perform migration
        if [[ "$SELECTED_SOURCE" == "__ALL__" ]]; then
            # Migrate from all source storages
            while IFS= read -r src_storage; do
                [[ -z "$src_storage" ]] && continue
                perform_migration "$SELECTED_VM" "$src_storage" "$SELECTED_DEST" "$offline" "$disk_format"
            done <<< "$SOURCE_STORAGES"
        else
            perform_migration "$SELECTED_VM" "$SELECTED_SOURCE" "$SELECTED_DEST" "$offline" "$disk_format"
        fi
        
        echo ""
        log_success "Migration process complete!"
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function
main "$@"
