#!/bin/bash
# Proxmox Cluster Rebalancing Script
# Distributes VMs based on resource allocation (memory/CPU)
# Uses Proxmox API - works from any node

set -o pipefail

echo "=== Proxmox Cluster Rebalancing Tool ==="
echo ""

# Check for jq
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: apt install jq -y"
    exit 1
fi

# Balancing mode: "memory", "cpu", or "count"
BALANCE_MODE="${1:-memory}"
DEBUG="${2:-false}"

echo "Balance mode: $BALANCE_MODE"
echo "(Usage: $0 [memory|cpu|count] [debug])"
echo ""

# Get all nodes in cluster using API
mapfile -t NODES < <(pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[].node' | sort)

NODE_COUNT=${#NODES[@]}

if [ $NODE_COUNT -lt 2 ]; then
    echo "Error: Need at least 2 nodes in cluster"
    exit 1
fi

echo "Cluster nodes found: ${NODES[*]}"
echo "Total nodes: $NODE_COUNT"
echo ""

# Function to format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1048576}")MB"
    else
        echo "${bytes}B"
    fi
}

# Gather node capacity info
echo "=== Node Capacity ==="
declare -A NODE_TOTAL_MEM
declare -A NODE_TOTAL_CPU

for node in "${NODES[@]}"; do
    node_status=$(pvesh get /nodes/"$node"/status --output-format=json 2>/dev/null)
    total_mem=$(echo "$node_status" | jq -r '.memory.total')
    total_cpu=$(echo "$node_status" | jq -r '.cpuinfo.cpus')
    NODE_TOTAL_MEM[$node]=$total_mem
    NODE_TOTAL_CPU[$node]=$total_cpu
    echo "  $node: $(format_bytes $total_mem) RAM, $total_cpu CPUs"
done
echo ""

# Gather VM info and calculate allocations per node
echo "=== Current VM Distribution ==="
declare -A NODE_ALLOC_MEM
declare -A NODE_ALLOC_CPU
declare -A NODE_VM_COUNT

for node in "${NODES[@]}"; do
    vms=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    
    vm_count=$(echo "$vms" | jq 'length')
    alloc_mem=$(echo "$vms" | jq '[.[].maxmem] | add // 0')
    alloc_cpu=$(echo "$vms" | jq '[.[].cpus // .[].maxcpu] | add // 0')
    
    NODE_VM_COUNT[$node]=${vm_count:-0}
    NODE_ALLOC_MEM[$node]=${alloc_mem:-0}
    NODE_ALLOC_CPU[$node]=${alloc_cpu:-0}
    
    mem_pct=$(awk "BEGIN {printf \"%.1f\", (${alloc_mem:-0}/${NODE_TOTAL_MEM[$node]})*100}")
    
    echo "  $node: ${NODE_VM_COUNT[$node]} VMs, $(format_bytes ${alloc_mem:-0}) allocated ($mem_pct%), ${alloc_cpu:-0} vCPUs"
done
echo ""

# Calculate totals and targets
TOTAL_ALLOC_MEM=0
TOTAL_ALLOC_CPU=0
TOTAL_VMS=0

for node in "${NODES[@]}"; do
    TOTAL_ALLOC_MEM=$((TOTAL_ALLOC_MEM + NODE_ALLOC_MEM[$node]))
    TOTAL_ALLOC_CPU=$((TOTAL_ALLOC_CPU + NODE_ALLOC_CPU[$node]))
    TOTAL_VMS=$((TOTAL_VMS + NODE_VM_COUNT[$node]))
done

TARGET_MEM=$((TOTAL_ALLOC_MEM / NODE_COUNT))
TARGET_CPU=$((TOTAL_ALLOC_CPU / NODE_COUNT))
TARGET_COUNT=$((TOTAL_VMS / NODE_COUNT))

echo "=== Targets (Equal Distribution) ==="
echo "  Memory: $(format_bytes $TARGET_MEM) per node"
echo "  vCPUs: $TARGET_CPU per node"
echo "  VMs: $TARGET_COUNT per node"
echo ""

# Function to get node load based on mode
get_node_load() {
    local node=$1
    case $BALANCE_MODE in
        memory) echo "${NODE_ALLOC_MEM[$node]}" ;;
        cpu)    echo "${NODE_ALLOC_CPU[$node]}" ;;
        count)  echo "${NODE_VM_COUNT[$node]}" ;;
    esac
}

get_target() {
    case $BALANCE_MODE in
        memory) echo "$TARGET_MEM" ;;
        cpu)    echo "$TARGET_CPU" ;;
        count)  echo "$TARGET_COUNT" ;;
    esac
}

# Check imbalance
echo "=== Imbalance Analysis ==="
TARGET=$(get_target)
THRESHOLD=$((TARGET / 10))  # 10% threshold
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=1

NEEDS_REBALANCE=false
for node in "${NODES[@]}"; do
    load=$(get_node_load "$node")
    diff=$((load - TARGET))
    if [ "$diff" -gt "$THRESHOLD" ]; then
        echo "  $node: OVERLOADED by $(format_bytes $diff)"
        NEEDS_REBALANCE=true
    elif [ "$diff" -lt "-$THRESHOLD" ]; then
        echo "  $node: UNDERLOADED by $(format_bytes $((-diff)))"
    else
        echo "  $node: BALANCED"
    fi
done
echo ""

if [ "$NEEDS_REBALANCE" = false ]; then
    echo "Cluster is already balanced. No action needed."
    exit 0
fi

# Ask for confirmation
read -p "Proceed with rebalancing? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Rebalancing cancelled"
    exit 0
fi

echo ""
echo "=== Starting Rebalancing ==="

# Build list of all VMs with their resources
declare -A VM_NODE
declare -A VM_MEM
declare -A VM_CPU

echo ""
echo "Gathering VM information..."

for node in "${NODES[@]}"; do
    vm_json=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    
    while IFS= read -r vmid; do
        [ -z "$vmid" ] || [ "$vmid" = "null" ] && continue
        
        vm_mem=$(echo "$vm_json" | jq -r ".[] | select(.vmid==$vmid) | .maxmem")
        vm_cpu=$(echo "$vm_json" | jq -r ".[] | select(.vmid==$vmid) | .cpus // .maxcpu // 1")
        vm_status=$(echo "$vm_json" | jq -r ".[] | select(.vmid==$vmid) | .status")
        
        VM_NODE[$vmid]=$node
        VM_MEM[$vmid]=$vm_mem
        VM_CPU[$vmid]=$vm_cpu
        
        [ "$DEBUG" = "debug" ] && echo "  Found VM $vmid on $node: $(format_bytes $vm_mem), $vm_cpu vCPU, status: $vm_status"
        
    done < <(echo "$vm_json" | jq -r '.[].vmid')
done

VM_TOTAL=${#VM_NODE[@]}
echo "Found $VM_TOTAL VMs across cluster"
echo ""

if [ "$VM_TOTAL" -eq 0 ]; then
    echo "ERROR: No VMs found!"
    exit 1
fi

# Rebalance loop
MAX_MIGRATIONS=20
migrations=0

while [ $migrations -lt $MAX_MIGRATIONS ]; do
    # Find most overloaded node
    max_node=""
    max_load=0
    TARGET=$(get_target)
    
    for node in "${NODES[@]}"; do
        load=$(get_node_load "$node")
        threshold_check=$((TARGET + THRESHOLD))
        
        if [ "$load" -gt "$threshold_check" ] && [ "$load" -gt "$max_load" ]; then
            max_load=$load
            max_node=$node
        fi
    done
    
    if [ -z "$max_node" ]; then
        echo "All nodes are now balanced."
        break
    fi
    
    # Find least loaded node
    min_node=""
    min_load=999999999999
    
    for node in "${NODES[@]}"; do
        load=$(get_node_load "$node")
        if [ "$node" != "$max_node" ] && [ "$load" -lt "$min_load" ]; then
            min_load=$load
            min_node=$node
        fi
    done
    
    # Find best VM to migrate
    best_vmid=""
    best_score=999999999999
    
    for vmid in "${!VM_NODE[@]}"; do
        if [ "${VM_NODE[$vmid]}" != "$max_node" ]; then
            continue
        fi
        
        case $BALANCE_MODE in
            memory) vm_size=${VM_MEM[$vmid]} ;;
            cpu)    vm_size=${VM_CPU[$vmid]} ;;
            count)  vm_size=1 ;;
        esac
        
        new_source_load=$((max_load - vm_size))
        new_target_load=$((min_load + vm_size))
        
        source_diff=$((new_source_load - TARGET))
        target_diff=$((new_target_load - TARGET))
        [ "$source_diff" -lt 0 ] && source_diff=$((-source_diff))
        [ "$target_diff" -lt 0 ] && target_diff=$((-target_diff))
        score=$((source_diff + target_diff))
        
        if [ "$score" -lt "$best_score" ]; then
            best_score=$score
            best_vmid=$vmid
        fi
    done
    
    if [ -z "$best_vmid" ]; then
        echo "No suitable VM found to migrate from $max_node"
        break
    fi
    
    # Get VM details
    vm_name=$(pvesh get /nodes/"$max_node"/qemu/"$best_vmid"/status/current --output-format=json 2>/dev/null | jq -r '.name // "unknown"')
    vm_status=$(pvesh get /nodes/"$max_node"/qemu/"$best_vmid"/status/current --output-format=json 2>/dev/null | jq -r '.status')
    vm_mem_hr=$(format_bytes ${VM_MEM[$best_vmid]})
    
    echo ""
    echo "Migrating VM $best_vmid ($vm_name) [$vm_mem_hr, ${VM_CPU[$best_vmid]} vCPU]: $max_node → $min_node"
    
    # Perform migration using API (works from any node in cluster)
    if [ "$vm_status" = "running" ]; then
        echo "  Status: running - using online migration"
        migrate_result=$(pvesh create /nodes/"$max_node"/qemu/"$best_vmid"/migrate \
            --target "$min_node" \
            --online 1 \
            --with-local-disks 0 \
            --output-format=json 2>&1)
    else
        echo "  Status: $vm_status - using offline migration"
        migrate_result=$(pvesh create /nodes/"$max_node"/qemu/"$best_vmid"/migrate \
            --target "$min_node" \
            --output-format=json 2>&1)
    fi
    
    # Check if we got a task ID (UPID) back - means migration started
    if echo "$migrate_result" | grep -q "UPID:"; then
        task_upid=$(echo "$migrate_result" | tr -d '"')
        echo "  Task started: $task_upid"
        
        # Wait for migration to complete
        echo "  Waiting for migration to complete..."
        while true; do
            task_status=$(pvesh get /nodes/"$max_node"/tasks/"$task_upid"/status --output-format=json 2>/dev/null)
            status=$(echo "$task_status" | jq -r '.status')
            
            if [ "$status" = "stopped" ]; then
                exitstatus=$(echo "$task_status" | jq -r '.exitstatus')
                if [ "$exitstatus" = "OK" ]; then
                    echo "  ✓ Migration successful"
                    
                    # Update tracking
                    case $BALANCE_MODE in
                        memory)
                            NODE_ALLOC_MEM[$max_node]=$((NODE_ALLOC_MEM[$max_node] - VM_MEM[$best_vmid]))
                            NODE_ALLOC_MEM[$min_node]=$((NODE_ALLOC_MEM[$min_node] + VM_MEM[$best_vmid]))
                            ;;
                        cpu)
                            NODE_ALLOC_CPU[$max_node]=$((NODE_ALLOC_CPU[$max_node] - VM_CPU[$best_vmid]))
                            NODE_ALLOC_CPU[$min_node]=$((NODE_ALLOC_CPU[$min_node] + VM_CPU[$best_vmid]))
                            ;;
                        count)
                            NODE_VM_COUNT[$max_node]=$((NODE_VM_COUNT[$max_node] - 1))
                            NODE_VM_COUNT[$min_node]=$((NODE_VM_COUNT[$min_node] + 1))
                            ;;
                    esac
                    
                    VM_NODE[$best_vmid]=$min_node
                    ((migrations++))
                    break
                else
                    echo "  ✗ Migration failed: $exitstatus"
                    unset "VM_NODE[$best_vmid]"
                    break
                fi
            fi
            sleep 3
        done
    else
        echo "  ✗ Failed to start migration: $migrate_result"
        unset "VM_NODE[$best_vmid]"
    fi
done

echo ""
echo "=== Rebalancing Complete ==="
echo "Migrations performed: $migrations"
echo ""
echo "Final distribution:"
for node in "${NODES[@]}"; do
    vms=$(pvesh get /nodes/"$node"/qemu --output-format=json 2>/dev/null)
    vm_count=$(echo "$vms" | jq 'length')
    alloc_mem=$(echo "$vms" | jq '[.[].maxmem] | add // 0')
    alloc_cpu=$(echo "$vms" | jq '[.[].cpus // .[].maxcpu] | add // 0')
    echo "  $node: $vm_count VMs, $(format_bytes $alloc_mem), $alloc_cpu vCPUs"
done
