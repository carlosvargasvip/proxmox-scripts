#!/bin/bash
# Proxmox Cluster Rebalancing Script
# Capacity-aware: balances by utilization percentage

echo "=== Proxmox Cluster Rebalancing Tool ==="
echo ""

if ! command -v jq &>/dev/null; then
    echo "Error: jq required. Run: apt install jq -y"
    exit 1
fi

BALANCE_MODE="${1:-memory}"
echo "Balance mode: $BALANCE_MODE"
echo ""

mapfile -t NODES < <(pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[].node' | sort)
NODE_COUNT=${#NODES[@]}

if [ $NODE_COUNT -lt 2 ]; then
    echo "Error: Need at least 2 nodes"
    exit 1
fi

echo "Nodes: ${NODES[*]}"
echo ""

format_bytes() {
    local bytes=${1:-0}
    [ -z "$bytes" ] && bytes=0
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fGB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.0fMB\", $bytes/1048576}"
    else
        echo "0MB"
    fi
}

# Get HA resources list once
HA_RESOURCES=$(pvesh get /cluster/ha/resources --output-format=json 2>/dev/null)

is_ha_vm() {
    local vmid=$1
    echo "$HA_RESOURCES" | jq -e ".[] | select(.sid==\"vm:$vmid\")" >/dev/null 2>&1
}

# Gather node capacity
echo "=== Node Capacity ==="
declare -A NODE_TOTAL_MEM NODE_TOTAL_CPU

for node in "${NODES[@]}"; do
    node_status=$(pvesh get /nodes/"$node"/status --output-format=json 2>/dev/null)
    NODE_TOTAL_MEM[$node]=$(echo "$node_status" | jq -r '.memory.total // 0')
    NODE_TOTAL_CPU[$node]=$(echo "$node_status" | jq -r '.cpuinfo.cpus // 1')
    echo "  $node: $(format_bytes ${NODE_TOTAL_MEM[$node]}) RAM, ${NODE_TOTAL_CPU[$node]} CPUs"
done
echo ""

# Gather current allocation
echo "=== Current Distribution ==="
declare -A NODE_ALLOC_MEM NODE_ALLOC_CPU NODE_VM_COUNT

for node in "${NODES[@]}"; do
    vms=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    
    vm_count=$(echo "$vms" | jq 'length // 0')
    alloc_mem=$(echo "$vms" | jq '[.[].maxmem] | add // 0')
    alloc_cpu=$(echo "$vms" | jq '[.[].cpus // .[].maxcpu] | add // 0')
    
    # Ensure we have numbers, default to 0
    [ -z "$vm_count" ] && vm_count=0
    [ -z "$alloc_mem" ] && alloc_mem=0
    [ -z "$alloc_cpu" ] && alloc_cpu=0
    [ "$alloc_mem" = "null" ] && alloc_mem=0
    [ "$alloc_cpu" = "null" ] && alloc_cpu=0
    
    NODE_VM_COUNT[$node]=$vm_count
    NODE_ALLOC_MEM[$node]=$alloc_mem
    NODE_ALLOC_CPU[$node]=$alloc_cpu
    
    # Calculate percentages safely
    total_mem=${NODE_TOTAL_MEM[$node]:-1}
    total_cpu=${NODE_TOTAL_CPU[$node]:-1}
    [ "$total_mem" -eq 0 ] && total_mem=1
    [ "$total_cpu" -eq 0 ] && total_cpu=1
    
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($alloc_mem/$total_mem)*100}")
    cpu_pct=$(awk "BEGIN {printf \"%.1f\", ($alloc_cpu/$total_cpu)*100}")
    
    echo "  $node: $vm_count VMs, $(format_bytes $alloc_mem)/$(format_bytes $total_mem) ($mem_pct%), $alloc_cpu/$total_cpu vCPUs ($cpu_pct%)"
done
echo ""

# Calculate cluster totals
TOTAL_ALLOC_MEM=0 
TOTAL_ALLOC_CPU=0 
TOTAL_VMS=0
TOTAL_CAPACITY_MEM=0 
TOTAL_CAPACITY_CPU=0

for node in "${NODES[@]}"; do
    TOTAL_ALLOC_MEM=$((TOTAL_ALLOC_MEM + ${NODE_ALLOC_MEM[$node]:-0}))
    TOTAL_ALLOC_CPU=$((TOTAL_ALLOC_CPU + ${NODE_ALLOC_CPU[$node]:-0}))
    TOTAL_VMS=$((TOTAL_VMS + ${NODE_VM_COUNT[$node]:-0}))
    TOTAL_CAPACITY_MEM=$((TOTAL_CAPACITY_MEM + ${NODE_TOTAL_MEM[$node]:-0}))
    TOTAL_CAPACITY_CPU=$((TOTAL_CAPACITY_CPU + ${NODE_TOTAL_CPU[$node]:-0}))
done

# Target utilization percentage
if [ "$TOTAL_CAPACITY_MEM" -gt 0 ]; then
    TARGET_MEM_PCT=$(awk "BEGIN {printf \"%.6f\", $TOTAL_ALLOC_MEM/$TOTAL_CAPACITY_MEM}")
else
    TARGET_MEM_PCT="0"
fi

if [ "$TOTAL_CAPACITY_CPU" -gt 0 ]; then
    TARGET_CPU_PCT=$(awk "BEGIN {printf \"%.6f\", $TOTAL_ALLOC_CPU/$TOTAL_CAPACITY_CPU}")
else
    TARGET_CPU_PCT="0"
fi

echo "=== Cluster Summary ==="
echo "  Total allocated: $(format_bytes $TOTAL_ALLOC_MEM) / $(format_bytes $TOTAL_CAPACITY_MEM) RAM"
echo "  Total vCPUs: $TOTAL_ALLOC_CPU / $TOTAL_CAPACITY_CPU"
target_mem_display=$(awk "BEGIN {printf \"%.1f\", $TARGET_MEM_PCT*100}")
target_cpu_display=$(awk "BEGIN {printf \"%.1f\", $TARGET_CPU_PCT*100}")
echo "  Target utilization: ${target_mem_display}% RAM, ${target_cpu_display}% CPU"
echo ""

# Calculate target allocation for each node
echo "=== Target Allocation (Capacity-Aware) ==="
declare -A NODE_TARGET_MEM NODE_TARGET_CPU

for node in "${NODES[@]}"; do
    NODE_TARGET_MEM[$node]=$(awk "BEGIN {printf \"%.0f\", ${NODE_TOTAL_MEM[$node]:-0} * $TARGET_MEM_PCT}")
    NODE_TARGET_CPU[$node]=$(awk "BEGIN {printf \"%.0f\", ${NODE_TOTAL_CPU[$node]:-0} * $TARGET_CPU_PCT}")
    echo "  $node: $(format_bytes ${NODE_TARGET_MEM[$node]}) RAM, ${NODE_TARGET_CPU[$node]} vCPUs"
done
echo ""

# Function to get utilization percentage
get_node_util_pct() {
    local node=$1
    local alloc=0
    local total=1
    
    case $BALANCE_MODE in
        memory) 
            alloc=${NODE_ALLOC_MEM[$node]:-0}
            total=${NODE_TOTAL_MEM[$node]:-1}
            ;;
        cpu)
            alloc=${NODE_ALLOC_CPU[$node]:-0}
            total=${NODE_TOTAL_CPU[$node]:-1}
            ;;
        count)
            echo "${NODE_VM_COUNT[$node]:-0}"
            return
            ;;
    esac
    
    [ -z "$alloc" ] && alloc=0
    [ -z "$total" ] || [ "$total" -eq 0 ] && total=1
    
    awk "BEGIN {printf \"%.0f\", ($alloc/$total)*10000}"
}

get_target_util_pct() {
    case $BALANCE_MODE in
        memory) awk "BEGIN {printf \"%.0f\", $TARGET_MEM_PCT*10000}" ;;
        cpu)    awk "BEGIN {printf \"%.0f\", $TARGET_CPU_PCT*10000}" ;;
        count)  echo "$((TOTAL_VMS / NODE_COUNT))" ;;
    esac
}

# Check imbalance
echo "=== Imbalance Analysis ==="
TARGET_PCT=$(get_target_util_pct)
THRESHOLD=$((TARGET_PCT / 10))
[ "$THRESHOLD" -lt 100 ] && THRESHOLD=100

NEEDS_REBALANCE=false
for node in "${NODES[@]}"; do
    util=$(get_node_util_pct "$node")
    diff=$((util - TARGET_PCT))
    
    if [ "$BALANCE_MODE" = "count" ]; then
        target_count=$((TOTAL_VMS / NODE_COUNT))
        if [ "${NODE_VM_COUNT[$node]:-0}" -gt "$((target_count + 1))" ]; then
            echo "  $node: OVERLOADED (${NODE_VM_COUNT[$node]} VMs, target ~$target_count)"
            NEEDS_REBALANCE=true
        elif [ "${NODE_VM_COUNT[$node]:-0}" -lt "$((target_count - 1))" ]; then
            echo "  $node: UNDERLOADED (${NODE_VM_COUNT[$node]} VMs, target ~$target_count)"
        else
            echo "  $node: BALANCED (${NODE_VM_COUNT[$node]} VMs)"
        fi
    else
        util_display=$(awk "BEGIN {printf \"%.1f\", $util/100}")
        target_display=$(awk "BEGIN {printf \"%.1f\", $TARGET_PCT/100}")
        
        if [ "$diff" -gt "$THRESHOLD" ]; then
            echo "  $node: OVERLOADED (${util_display}% vs target ${target_display}%)"
            NEEDS_REBALANCE=true
        elif [ "$diff" -lt "-$THRESHOLD" ]; then
            echo "  $node: UNDERLOADED (${util_display}% vs target ${target_display}%)"
        else
            echo "  $node: BALANCED (${util_display}%)"
        fi
    fi
done
echo ""

if [ "$NEEDS_REBALANCE" = false ]; then
    echo "Cluster is already balanced. No action needed."
    exit 0
fi

# Build VM list
declare -A VM_NODE VM_MEM VM_CPU VM_HA

echo "=== VM Inventory ==="
ha_count=0
regular_count=0

for node in "${NODES[@]}"; do
    vm_json=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    while IFS= read -r vmid; do
        [ -z "$vmid" ] || [ "$vmid" = "null" ] && continue
        VM_NODE[$vmid]=$node
        VM_MEM[$vmid]=$(echo "$vm_json" | jq -r ".[] | select(.vmid==$vmid) | .maxmem // 0")
        VM_CPU[$vmid]=$(echo "$vm_json" | jq -r ".[] | select(.vmid==$vmid) | .cpus // .maxcpu // 1")
        
        if is_ha_vm "$vmid"; then
            VM_HA[$vmid]=1
            ((ha_count++))
        else
            VM_HA[$vmid]=0
            ((regular_count++))
        fi
    done < <(echo "$vm_json" | jq -r '.[].vmid')
done

echo "  Total VMs: ${#VM_NODE[@]}"
echo "  HA-managed: $ha_count"
echo "  Regular: $regular_count"
echo ""

if [ $ha_count -gt 0 ]; then
    echo "HA-managed VMs:"
    for vmid in "${!VM_HA[@]}"; do
        if [ "${VM_HA[$vmid]}" -eq 1 ]; then
            vm_name=$(pvesh get /nodes/"${VM_NODE[$vmid]}"/qemu/"$vmid"/status/current --output-format=json 2>/dev/null | jq -r '.name // "unknown"')
            echo "  VM $vmid ($vm_name) on ${VM_NODE[$vmid]}"
        fi
    done
    echo ""
fi

read -p "Proceed with rebalancing? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && exit 0

echo ""
echo "=== Starting Rebalancing ==="

migrations=0
MAX=20

while [ $migrations -lt $MAX ]; do
    # Find most overloaded node
    max_node="" 
    max_util=0
    TARGET_PCT=$(get_target_util_pct)
    
    for node in "${NODES[@]}"; do
        util=$(get_node_util_pct "$node")
        if [ "$util" -gt "$((TARGET_PCT + THRESHOLD))" ] && [ "$util" -gt "$max_util" ]; then
            max_util=$util
            max_node=$node
        fi
    done
    [ -z "$max_node" ] && { echo ""; echo "Cluster balanced."; break; }

    # Find least loaded node
    min_node="" 
    min_util=9999999
    for node in "${NODES[@]}"; do
        util=$(get_node_util_pct "$node")
        [ "$node" != "$max_node" ] && [ "$util" -lt "$min_util" ] && { min_util=$util; min_node=$node; }
    done

    # Find best VM to migrate
    best_vmid="" 
    best_score=999999999999
    
    for vmid in "${!VM_NODE[@]}"; do
        [ "${VM_NODE[$vmid]}" != "$max_node" ] && continue
        
        vm_mem=${VM_MEM[$vmid]:-0}
        vm_cpu=${VM_CPU[$vmid]:-0}
        
        src_alloc_mem=${NODE_ALLOC_MEM[$max_node]:-0}
        dst_alloc_mem=${NODE_ALLOC_MEM[$min_node]:-0}
        src_alloc_cpu=${NODE_ALLOC_CPU[$max_node]:-0}
        dst_alloc_cpu=${NODE_ALLOC_CPU[$min_node]:-0}
        src_total_mem=${NODE_TOTAL_MEM[$max_node]:-1}
        dst_total_mem=${NODE_TOTAL_MEM[$min_node]:-1}
        src_total_cpu=${NODE_TOTAL_CPU[$max_node]:-1}
        dst_total_cpu=${NODE_TOTAL_CPU[$min_node]:-1}
        
        [ "$src_total_mem" -eq 0 ] && src_total_mem=1
        [ "$dst_total_mem" -eq 0 ] && dst_total_mem=1
        [ "$src_total_cpu" -eq 0 ] && src_total_cpu=1
        [ "$dst_total_cpu" -eq 0 ] && dst_total_cpu=1
        
        case $BALANCE_MODE in
            memory)
                new_src_alloc=$((src_alloc_mem - vm_mem))
                new_dst_alloc=$((dst_alloc_mem + vm_mem))
                new_src_util=$(awk "BEGIN {printf \"%.0f\", ($new_src_alloc/$src_total_mem)*10000}")
                new_dst_util=$(awk "BEGIN {printf \"%.0f\", ($new_dst_alloc/$dst_total_mem)*10000}")
                ;;
            cpu)
                new_src_alloc=$((src_alloc_cpu - vm_cpu))
                new_dst_alloc=$((dst_alloc_cpu + vm_cpu))
                new_src_util=$(awk "BEGIN {printf \"%.0f\", ($new_src_alloc/$src_total_cpu)*10000}")
                new_dst_util=$(awk "BEGIN {printf \"%.0f\", ($new_dst_alloc/$dst_total_cpu)*10000}")
                ;;
            count)
                new_src_util=$((${NODE_VM_COUNT[$max_node]:-0} - 1))
                new_dst_util=$((${NODE_VM_COUNT[$min_node]:-0} + 1))
                ;;
        esac
        
        # Score: sum of absolute differences from target
        src_diff=$((new_src_util - TARGET_PCT))
        dst_diff=$((new_dst_util - TARGET_PCT))
        [ "$src_diff" -lt 0 ] && src_diff=$((-src_diff))
        [ "$dst_diff" -lt 0 ] && dst_diff=$((-dst_diff))
        score=$((src_diff + dst_diff))
        
        # Don't overload destination
        if [ "$new_dst_util" -gt "$((TARGET_PCT + THRESHOLD * 2))" ]; then
            continue
        fi
        
        [ "$score" -lt "$best_score" ] && { best_score=$score; best_vmid=$vmid; }
    done
    
    [ -z "$best_vmid" ] && { echo "No suitable VM to migrate from $max_node"; break; }

    vm_info=$(pvesh get /nodes/"$max_node"/qemu/"$best_vmid"/status/current --output-format=json 2>/dev/null)
    vm_name=$(echo "$vm_info" | jq -r '.name // "unknown"')
    vm_status=$(echo "$vm_info" | jq -r '.status')
    
    if [ "${VM_HA[$best_vmid]:-0}" -eq 1 ]; then
        ha_label="[HA]"
    else
        ha_label=""
    fi
    
    src_util_display=$(awk "BEGIN {printf \"%.1f\", $(get_node_util_pct $max_node)/100}")
    dst_util_display=$(awk "BEGIN {printf \"%.1f\", $(get_node_util_pct $min_node)/100}")

    echo ""
    echo "[$((migrations + 1))] VM $best_vmid ($vm_name) $ha_label: $max_node ($src_util_display%) → $min_node ($dst_util_display%)"

    if [ "$vm_status" = "running" ]; then
        echo "  Starting online migration..."
        result=$(pvesh create /nodes/"$max_node"/qemu/"$best_vmid"/migrate \
            --target "$min_node" --online 1 2>&1)
    else
        echo "  Starting offline migration..."
        result=$(pvesh create /nodes/"$max_node"/qemu/"$best_vmid"/migrate \
            --target "$min_node" 2>&1)
    fi

    if [[ "$result" == *"UPID:"* ]]; then
        upid=$(echo "$result" | grep -oP 'UPID:[^"]+' | head -1)
        
        if [ "${VM_HA[$best_vmid]:-0}" -eq 1 ]; then
            echo "  HA migration task: $upid"
            timeout=180
        else
            echo "  Migration task: $upid"
            timeout=120
        fi
        
        echo -n "  Waiting"
        success=false
        for ((i=1; i<=timeout; i++)); do
            if pvesh get /nodes/"$min_node"/qemu/"$best_vmid"/status/current --output-format=json &>/dev/null; then
                echo " done!"
                success=true
                break
            fi
            
            if ! pvesh get /nodes/"$max_node"/qemu/"$best_vmid"/status/current --output-format=json &>/dev/null; then
                sleep 2
                if pvesh get /nodes/"$min_node"/qemu/"$best_vmid"/status/current --output-format=json &>/dev/null; then
                    echo " done!"
                    success=true
                    break
                fi
            fi
            
            echo -n "."
            sleep 3
        done
        
        if [ "$success" = true ]; then
            # Update allocations
            NODE_ALLOC_MEM[$max_node]=$((${NODE_ALLOC_MEM[$max_node]:-0} - ${VM_MEM[$best_vmid]:-0}))
            NODE_ALLOC_MEM[$min_node]=$((${NODE_ALLOC_MEM[$min_node]:-0} + ${VM_MEM[$best_vmid]:-0}))
            NODE_ALLOC_CPU[$max_node]=$((${NODE_ALLOC_CPU[$max_node]:-0} - ${VM_CPU[$best_vmid]:-0}))
            NODE_ALLOC_CPU[$min_node]=$((${NODE_ALLOC_CPU[$min_node]:-0} + ${VM_CPU[$best_vmid]:-0}))
            NODE_VM_COUNT[$max_node]=$((${NODE_VM_COUNT[$max_node]:-0} - 1))
            NODE_VM_COUNT[$min_node]=$((${NODE_VM_COUNT[$min_node]:-0} + 1))
            
            VM_NODE[$best_vmid]=$min_node
            ((migrations++))
            
            new_src_util=$(awk "BEGIN {printf \"%.1f\", $(get_node_util_pct $max_node)/100}")
            new_dst_util=$(awk "BEGIN {printf \"%.1f\", $(get_node_util_pct $min_node)/100}")
            echo "  ✓ Success ($max_node: $new_src_util%, $min_node: $new_dst_util%)"
        else
            echo " timeout!"
            echo "  ⚠ Check Proxmox UI for status"
            unset "VM_NODE[$best_vmid]"
        fi
    else
        echo "  ✗ Failed: $result"
        unset "VM_NODE[$best_vmid]"
    fi
done

echo ""
echo "=== Complete ==="
echo "Migrations: $migrations"
echo ""
echo "Final distribution:"
for node in "${NODES[@]}"; do
    vms=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    alloc_mem=$(echo "$vms" | jq '[.[].maxmem] | add // 0')
    [ -z "$alloc_mem" ] || [ "$alloc_mem" = "null" ] && alloc_mem=0
    total_mem=${NODE_TOTAL_MEM[$node]:-1}
    [ "$total_mem" -eq 0 ] && total_mem=1
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($alloc_mem/$total_mem)*100}")
    echo "  $node: $(echo "$vms" | jq 'length') VMs, $(format_bytes $alloc_mem) ($mem_pct%)"
done
