#!/bin/bash

# Proxmox Cluster Rebalancing Script
# Distributes VMs evenly across all cluster nodes

echo "=== Proxmox Cluster Rebalancing Tool ==="
echo ""

# Get all nodes in cluster
mapfile -t NODES < <(pvecm nodes | awk 'NR>4 {print $3}')
NODE_COUNT=${#NODES[@]}

if [ $NODE_COUNT -lt 2 ]; then
    echo "Error: Need at least 2 nodes in cluster"
    exit 1
fi

echo "Cluster nodes found: ${NODES[*]}"
echo "Total nodes: $NODE_COUNT"
echo ""

# Count VMs per node
echo "Current VM distribution:"
declare -A VM_COUNT
for node in "${NODES[@]}"; do
    count=$(ssh $node "qm list | tail -n +2 | wc -l")
    VM_COUNT[$node]=$count
    echo "  $node: $count VMs"
done
echo ""

# Calculate total VMs and target per node
TOTAL_VMS=0
for count in "${VM_COUNT[@]}"; do
    TOTAL_VMS=$((TOTAL_VMS + count))
done

TARGET_PER_NODE=$((TOTAL_VMS / NODE_COUNT))
echo "Total VMs: $TOTAL_VMS"
echo "Target per node: $TARGET_PER_NODE"
echo ""

# Ask for confirmation
read -p "Proceed with rebalancing? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Rebalancing cancelled"
    exit 0
fi

echo ""
echo "=== Starting Rebalancing ==="

# Rebalance logic: Move VMs from overloaded to underloaded nodes
for source_node in "${NODES[@]}"; do
    while [ ${VM_COUNT[$source_node]} -gt $((TARGET_PER_NODE + 1)) ]; do
        # Find node with least VMs
        min_node=""
        min_count=999999
        for node in "${NODES[@]}"; do
            if [ "$node" != "$source_node" ] && [ ${VM_COUNT[$node]} -lt $min_count ]; then
                min_node=$node
                min_count=${VM_COUNT[$node]}
            fi
        done
        
        # Get first running VM from source node
        vmid=$(ssh $source_node "qm list | awk '\$3==\"running\" {print \$1; exit}'")
        
        if [ -z "$vmid" ]; then
            echo "No more running VMs to migrate from $source_node"
            break
        fi
        
        echo "Migrating VM $vmid: $source_node → $min_node"
        ssh $source_node "qm migrate $vmid $min_node --online" 2>&1 | grep -v "^$"
        
        # Update counts
        VM_COUNT[$source_node]=$((VM_COUNT[$source_node] - 1))
        VM_COUNT[$min_node]=$((VM_COUNT[$min_node] + 1))
        
        echo "  Current: $source_node=${VM_COUNT[$source_node]}, $min_node=${VM_COUNT[$min_node]}"
    done
done

echo ""
echo "=== Rebalancing Complete ==="
echo "Final distribution:"
for node in "${NODES[@]}"; do
    count=$(ssh $node "qm list | tail -n +2 | wc -l")
    echo "  $node: $count VMs"
done
