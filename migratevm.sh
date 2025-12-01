#!/bin/bash

# Distribute VMs evenly across all other nodes
CURRENT_NODE=$(hostname)
mapfile -t TARGET_NODES < <(pvecm nodes | awk 'NR>4 {print $3}' | grep -v "$CURRENT_NODE")

if [ ${#TARGET_NODES[@]} -eq 0 ]; then
    echo "No other nodes available!"
    exit 1
fi

echo "Distributing VMs across: ${TARGET_NODES[*]}"

i=0
for vmid in $(qm list | awk '{if(NR>1) print $1}'); do
    TARGET_NODE=${TARGET_NODES[$((i % ${#TARGET_NODES[@]}))]}
    echo "Migrating VM $vmid to $TARGET_NODE..."
    qm migrate $vmid $TARGET_NODE --online
    ((i++))
done
