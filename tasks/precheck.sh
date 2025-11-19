#!/bin/bash

# Function to check if a value is numeric (handles . or , as decimal separator)
is_numeric() {
  NORMALIZED=$(echo "$1" | tr ',' '.')
  echo "$NORMALIZED" | grep -qE '^[0-9]+(\.[0-9]+)?$'
  return $?
}

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to check VM Details (detect hypervisor)
check_vm() {
  CMD="virt-what"
  if command_exists virt-what; then
    CMD_OUTPUT=$(virt-what || echo "No hypervisor detected")
    if [ -n "$CMD_OUTPUT" ] && [ "$CMD_OUTPUT" != "No hypervisor detected" ]; then
      STATUS="OK (VM, Hypervisor: $CMD_OUTPUT)"
    else
      STATUS="OK (Physical machine)"
      CMD_OUTPUT="No hypervisor detected"
    fi
  else
    CMD_OUTPUT="virt-what not installed"
    STATUS="OK (virt-what not installed)"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check CPU (at least 1 core, supported architecture)
check_cpu() {
  CMD="lscpu"
  CMD_OUTPUT=$(lscpu | grep -E 'Architecture|CPU\(s\):' | head -n 2 | tr '\n' '; ')
  ARCH=$(lscpu | grep Architecture | awk '{print $2}')
  CORES=$(lscpu | grep '^CPU(s):' | awk '{print $2}')
  if [[ "$ARCH" =~ ^(x86_64|aarch64|ppc64le|s390x)$ ]] && [ -n "$CORES" ] && [ "$CORES" -ge 1 ]; then
    STATUS="OK (Arch: $ARCH, Cores: $CORES)"
  else
    STATUS="NOT OK (Arch: ${ARCH:-Unknown}, Cores: ${CORES:-Unknown})"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check CPU Usage (threshold: <80%) using top
check_cpu_usage() {
  CMD="top -bn1 | grep '%Cpu'"
  if command_exists top; then
    TOP_OUTPUT=$(top -bn1 | grep '%Cpu')
    CPU_IDLE=$(echo "$TOP_OUTPUT" | awk '{print $8}' | tr -d '[:space:]' | tr ',' '.')
    CMD_OUTPUT=$(echo "$TOP_OUTPUT" | awk '{print "Idle: " $8 "%"}')
    if [ -z "$TOP_OUTPUT" ]; then
      STATUS="NOT OK (Usage: Unknown)"
      CMD_OUTPUT="Error: No %Cpu line found in top output"
    elif [ -n "$CPU_IDLE" ] && is_numeric "$CPU_IDLE"; then
      CPU_USAGE=$(echo "100 - $CPU_IDLE" | bc 2>/dev/null)
      if [ $? -eq 0 ] && [ -n "$CPU_USAGE" ]; then
        if (( $(echo "$CPU_USAGE < 80" | bc -l) )); then
          STATUS="OK (Usage: $CPU_USAGE%)"
        else
          STATUS="NOT OK (Usage: $CPU_USAGE%)"
        fi
      else
        STATUS="NOT OK (Usage: Unknown)"
        CMD_OUTPUT="Error calculating CPU usage"
      fi
    else
      STATUS="NOT OK (Usage: Unknown)"
      CMD_OUTPUT="Error retrieving CPU idle"
    fi
  else
    STATUS="OK (top not installed)"
    CMD_OUTPUT="top command not found"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check Memory (minimum 2GB)
check_memory() {
  CMD="free -h"
  CMD_OUTPUT=$(free -h | grep Mem | awk '{print $2 " total, " $3 " used, " $4 " free"}')
  TOTAL_MEM=$(free -h | grep Mem | awk '{print $2}' | tr -d 'G' | tr -d '[:space:]' | tr ',' '.')
  if [ -n "$TOTAL_MEM" ] && is_numeric "$TOTAL_MEM"; then
    if (( $(echo "$TOTAL_MEM >= 2" | bc -l) )); then
      STATUS="OK ($TOTAL_MEM GB)"
    else
      STATUS="NOT OK ($TOTAL_MEM GB, Minimum 2GB required)"
    fi
  else
    STATUS="NOT OK (Memory: Unknown)"
    CMD_OUTPUT="Error retrieving memory info"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check Memory Usage (threshold: <80%)
check_memory_usage() {
  CMD="free -h"
  CMD_OUTPUT=$(free -h | grep Mem | awk '{print $2 " total, " $3 " used, " $4 " free"}')
  TOTAL_MEM=$(free -m | grep Mem | awk '{print $2}' | tr -d '[:space:]' | tr ',' '.')
  USED_MEM=$(free -m | grep Mem | awk '{print $3}' | tr -d '[:space:]' | tr ',' '.')
  if [ -n "$TOTAL_MEM" ] && [ -n "$USED_MEM" ] && is_numeric "$TOTAL_MEM" && is_numeric "$USED_MEM" && [ "$(echo "$TOTAL_MEM > 0" | bc -l)" -eq 1 ]; then
    MEM_USAGE=$(echo "scale=2; ($USED_MEM / $TOTAL_MEM) * 100" | bc 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$MEM_USAGE" ]; then
      if (( $(echo "$MEM_USAGE < 80" | bc -l) )); then
        STATUS="OK (Usage: $MEM_USAGE%)"
      else
        STATUS="NOT OK (Usage: $MEM_USAGE%)"
      fi
    else
      STATUS="NOT OK (Usage: Unknown)"
      CMD_OUTPUT="Error calculating memory usage"
    fi
  else
    STATUS="NOT OK (Usage: Unknown)"
    CMD_OUTPUT="Error retrieving memory info"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check Number of Disks, Disk Usage (<90%), and Free Disk Space (≥10GB)
check_disks() {
  CMD="lsblk -d | grep disk; df -h /"
  CMD_DISKS=$(lsblk -d | grep disk | head -n 1 | awk '{print $1}')
  CMD_USAGE=$(df -h / | tail -1 | awk '{print $2 " total, " $5 " used, " $4 " free"}')
  CMD_OUTPUT="Disks: $CMD_DISKS; Usage: $CMD_USAGE"
  NUM_DISKS=$(lsblk -d | grep disk | wc -l)
  ROOT_USAGE=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
  FREE_SPACE=$(df -h / | tail -1 | awk '{print $4}' | tr -d 'G' | tr -d '[:space:]' | tr ',' '.')
  if [ -n "$FREE_SPACE" ] && is_numeric "$FREE_SPACE"; then
    if [ "$NUM_DISKS" -ge 1 ] && [ -n "$ROOT_USAGE" ] && [ "$ROOT_USAGE" -lt 90 ] && (( $(echo "$FREE_SPACE >= 10" | bc -l) )); then
      STATUS="OK (Disks: $NUM_DISKS, Usage: $ROOT_USAGE%, Free: $FREE_SPACE GB)"
    else
      STATUS="NOT OK (Disks: $NUM_DISKS, Usage: ${ROOT_USAGE:-Unknown}%, Free: ${FREE_SPACE:-Unknown} GB)"
    fi
  else
    STATUS="NOT OK (Disks: $NUM_DISKS, Usage: ${ROOT_USAGE:-Unknown}%, Free: ${FREE_SPACE:-Unknown} GB)"
    CMD_OUTPUT="Error retrieving disk info"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check Swap (at least some swap configured)
check_swap() {
  CMD="free -h"
  CMD_OUTPUT=$(free -h | grep Swap | awk '{print $2 " total"}')
  SWAP_TOTAL=$(free -h | grep Swap | awk '{print $2}' | tr -d '[:space:]')
  if [[ "$SWAP_TOTAL" != "0B" ]]; then
    STATUS="OK ($SWAP_TOTAL)"
  else
    STATUS="NOT OK (No swap configured)"
    CMD_OUTPUT="No swap configured"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check IP Details (list all available interface IPs)
check_ip() {
  CMD="ip addr show"
  CMD_OUTPUT=$(ip addr show | grep 'inet ' | awk '{print $2}' )
  IP_COUNT=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | wc -l)
  if [ "$IP_COUNT" -ge 1 ]; then
    STATUS="OK (IPs configured)"
    printf "%-65s %-25s\n" "" "$CMD_OUTPUT"
    printf "%-65s %-25s\n" "" "$status"
  else
    STATUS="NOT OK (No IPs configured)"
    CMD_OUTPUT="No IP addresses configured"
printf "%-65s  %-25s\n" "$CMD_OUTPUT" "$STATUS"
  fi
 # printf "%-65s  %-25s\n" "$CMD_OUTPUT" "$STATUS"
}

# Function to check Route Details (has default route)
check_route() {
  CMD="ip route"
  CMD_OUTPUT=$(ip route | grep default | head -n 1 | awk '{print $1 " via " $3}')
  DEFAULT_ROUTE=$(ip route | grep default | wc -l)
  if [ "$DEFAULT_ROUTE" -ge 1 ]; then
    STATUS="OK (Default route present)"
  else
    STATUS="NOT OK (No default route)"
    CMD_OUTPUT="No default route configured"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check SELinux Status (should be enabled and enforcing)
check_selinux() {
  CMD="getenforce"
  if command_exists getenforce; then
    CMD_OUTPUT=$(getenforce)
    if [ "$CMD_OUTPUT" = "Enforcing" ]; then
      STATUS="OK (SELinux Enforcing)"
    else
      STATUS="NOT OK (SELinux $CMD_OUTPUT)"
    fi
  else
    CMD_OUTPUT="SELinux not installed"
    STATUS="OK (SELinux not installed)"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check SSH Configuration (Protocol 2, PermitRootLogin no)
check_ssh_config() {
  CMD="sshd -T | grep -Ei 'protocol|permitrootlogin'"
  CMD_OUTPUT=$(sshd -T | grep -Ei '^(protocol|permitrootlogin)' | tr '\n' '; ')
  PROTOCOL=$(sshd -T | grep -Ei '^protocol' | awk '{print $2}')
  ROOT_LOGIN=$(sshd -T | grep -Ei '^permitrootlogin' | awk '{print $2}')
  if [ "$PROTOCOL" = "2" ] && [ "$ROOT_LOGIN" = "no" ]; then
    STATUS="OK (Protocol 2, Root Login Disabled)"
  else
    STATUS="NOT OK (Protocol: ${PROTOCOL:-Unknown}, PermitRootLogin: ${ROOT_LOGIN:-Unknown})"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "${CMD_OUTPUT:-No SSH configuration found}"
}

# Function to check services
check_service() {
  SERVICE=$1
  CMD="systemctl status $SERVICE"
  CMD_OUTPUT=$(systemctl status $SERVICE 2>/dev/null )
  AC_CHECK=$(echo $?)
    if [ "$AC_CHECK" = "0"  ]; then
    STATUS="OK"
    CMD_OUTPUT=$(systemctl status "$SERVICE" 2>&1 | head -n 1 |awk '{print $4 " " $5}')
  elif [ "$AC_CHECK" = "3" ]; then
    STATUS="NOT OK (Service $SERVICE not running)"
    CMD_OUTPUT="Service inactive/failed"
  elif [ "$AC_CHECK" = "4" ]; then
    STATUS="OK (Service $SERVICE not configured)"
    CMD_OUTPUT="Service Not configured "
   else
    STATUS="NOT OK (Unknown Error)"
    CMD_OUTPUT="Check the service"  
   fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check RHEL Cluster Status (pcs, pacemaker, corosync)
check_rhel_cluster() {
  CMD="pcs status"
  if command_exists pcs; then
    if systemctl is-active --quiet pacemaker; then
      PCS_OUTPUT=$(pcs status | head -n 3 | tr '\n' '; ')
      if echo "$PCS_OUTPUT" | grep -q "Cluster name"; then
        STATUS="OK (Pacemaker Active)"
      else
        STATUS="NOT OK (Cluster issues)"
      fi
    else
      STATUS="NOT OK (Pacemaker inactive)"
      PCS_OUTPUT="Pacemaker service inactive"
    fi
  else
    STATUS="OK (PCS not installed)"
    PCS_OUTPUT="Cluster tools not installed"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$PCS_OUTPUT"
}

# Function to check Corosync Status
check_corosync() {
  CMD="corosync-cfgtool -s"
  if command_exists corosync-cfgtool; then
    if systemctl is-active --quiet corosync; then
      COROSYNC_OUTPUT=$(corosync-cfgtool -s | head -n 1)
      if echo "$COROSYNC_OUTPUT" | grep -q "Printing"; then
        STATUS="OK (Corosync Active)"
      else
        STATUS="NOT OK (Corosync sync issues)"
      fi
    else
      STATUS="NOT OK (Corosync inactive)"
      COROSYNC_OUTPUT="Corosync service inactive"
    fi
  else
    STATUS="OK (Corosync tools not installed)"
    COROSYNC_OUTPUT="Corosync tools not installed"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$COROSYNC_OUTPUT"
}

# Function to check NFS fstab entries (not commented)
check_nfs_fstab() {
  CMD="grep nfs /etc/fstab"
  FSTAB_OUTPUT=$(grep -E '^(#|\s*)nfs' /etc/fstab | awk '{print $1 " " $2}' | tr '\n' '; ')
  ACTIVE_NFS=$(grep -v '^#' /etc/fstab | grep nfs | wc -l)
  COMMENTED_NFS=$(grep '^#.*nfs' /etc/fstab | wc -l)
  TOTAL_NFS=$(grep -i nfs /etc/fstab | wc -l)
  
  if [ "$TOTAL_NFS" -eq 0 ]; then
    STATUS="OK (No NFS entries in fstab)"
    FSTAB_OUTPUT="No NFS entries found"
  elif [ "$ACTIVE_NFS" -eq "$TOTAL_NFS" ]; then
    STATUS="OK ($ACTIVE_NFS active NFS entries)"
  elif [ "$ACTIVE_NFS" -lt "$TOTAL_NFS" ]; then
    STATUS="NOT OK ($ACTIVE_NFS active, $COMMENTED_NFS commented)"
  else
    STATUS="OK ($ACTIVE_NFS active NFS entries)"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$FSTAB_OUTPUT"
}

# Function to check NFS Mount Status
check_nfs_mounts() {
  CMD="df -h | grep nfs"
  NFS_MOUNTS=$(df -h | grep nfs | wc -l)
  if [ "$NFS_MOUNTS" -gt 0 ]; then
    NFS_OUTPUT=$(df -h | grep nfs | awk '{print $1 " " $6 " " $5 " used"}' | tr '\n' '; ')
    MOUNT_STATUS=$(df -h | grep nfs | awk '{print $5}' | tr -d '%' | awk '{if ($1 > 90) sum+=1} END {print sum}')
    if [ -z "$MOUNT_STATUS" ] || [ "$MOUNT_STATUS" -eq 0 ]; then
      STATUS="OK ($NFS_MOUNTS NFS mounts)"
    else
      STATUS="NOT OK ($NFS_MOUNTS NFS mounts, $MOUNT_STATUS over 90%)"
    fi
  else
    STATUS="OK (No NFS mounts)"
    NFS_OUTPUT="No NFS mounts detected"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$NFS_OUTPUT"
}

# Function to check NFS Services (nfs-server, nfs-utils)
check_nfs_services() {
  CMD="systemctl status nfs-server"
  if command_exists rpcinfo; then
    RPC_STATUS=$(rpcinfo -p | grep -E "(nfs|mountd)" | wc -l)
    if systemctl is-active --quiet rpcbind && [ "$RPC_STATUS" -gt 0 ]; then
      STATUS="OK (NFS services active)"
      CMD_OUTPUT="rpcbind: Active, NFS RPC: $RPC_STATUS services"
    else
      STATUS="NOT OK (NFS services inactive)"
      CMD_OUTPUT="rpcbind: $(systemctl is-active rpcbind), NFS RPC: $RPC_STATUS"
    fi
  else
    STATUS="OK (nfs-utils not installed)"
    CMD_OUTPUT="nfs-utils package missing"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Function to check Fencing Status (for HA clusters)
check_fencing() {
  CMD="pcs status fencing"
  if command_exists pcs; then
    FENCING_OUTPUT=$(pcs status fencing 2>/dev/null | head -n 1)
    if [ -n "$FENCING_OUTPUT" ] && echo "$FENCING_OUTPUT" | grep -q "Full list"; then
      STATUS="OK (Fencing configured)"
    else
      STATUS="NOT OK (Fencing issues)"
    fi
  else
    STATUS="OK (PCS not installed)"
    FENCING_OUTPUT="Cluster tools not installed"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "${FENCING_OUTPUT:-No fencing info}"
}

# SIMPLIFIED: Function to detect PostgreSQL server
check_postgres_server() {
  CMD="systemctl status postgresql | ss -tlnp | grep :5432"
  POSTGRES_SERVICE=$(systemctl is-active postgresql 2>/dev/null)
  POSTGRES_PORT=$(ss -tlnp | grep -q ":5432" && echo "Port 5432 listening")
  
  if [ "$POSTGRES_SERVICE" = "active" ] || [ -n "$POSTGRES_PORT" ]; then
    STATUS="OK (PostgreSQL Server Detected)"
    CMD_OUTPUT="Service: $POSTGRES_SERVICE; $POSTGRES_PORT"
  else
    STATUS="OK (No PostgreSQL Server)"
    CMD_OUTPUT="Service: $POSTGRES_SERVICE; Port 5432: Not listening"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# SIMPLIFIED: Function to detect MongoDB server
check_mongodb_server() {
  CMD="systemctl status mongod | ss -tlnp | grep :27017"
  MONGODB_SERVICE=$(systemctl is-active mongod 2>/dev/null)
  MONGODB_PORT=$(ss -tlnp | grep -q ":27017" && echo "Port 27017 listening")
  
  if [ "$MONGODB_SERVICE" = "active" ] || [ -n "$MONGODB_PORT" ]; then
    STATUS="OK (MongoDB Server Detected)"
    CMD_OUTPUT="Service: $MONGODB_SERVICE; $MONGODB_PORT"
  else
    STATUS="OK (No MongoDB Server)"
    CMD_OUTPUT="Service: $MONGODB_SERVICE; Port 27017: Not listening"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# SIMPLIFIED: Function to detect ANY OTHER Database servers
check_other_db_servers() {
  CMD="systemctl list-units | grep -E '(mysql|mariadb|oracle|redis|memcached)'"
  OTHER_DBS=$(systemctl list-units --state=active | grep -E "(mysql|mariadb|oracle|redis|memcached)" | awk '{print $1}' | tr '\n' '; ')
  
  if [ -n "$OTHER_DBS" ]; then
    STATUS="OK (Other DB Servers: $OTHER_DBS)"
    CMD_OUTPUT="$OTHER_DBS"
  else
    STATUS="OK (No Other DB Servers)"
    CMD_OUTPUT="MySQL/MariaDB/Oracle/Redis/Memcached: None active"
  fi
  printf "%-65s  %-45s  %-80s\n" "$CMD" "$STATUS" "$CMD_OUTPUT"
}

# Run checks and format output as table with spacing
{
  echo -e "Command                                                                 Status                                        Output"
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  
  # === SYSTEM BASICS ===
  echo -e "\n=== SYSTEM BASICS ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_vm; echo -e "\n"
  check_cpu; echo -e "\n"
  check_cpu_usage; echo -e "\n"
  check_memory; echo -e "\n"
  check_memory_usage; echo -e "\n"
  check_disks; echo -e "\n"
  check_swap; echo -e "\n"
  check_ip; echo -e "\n"
  check_route; echo -e "\n"
  
  # === SERVICES ===
  echo -e "\n=== SERVICES ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_service "opsbridge"; echo -e "\n"
  check_service "puppet"; echo -e "\n"
  check_service "centrifydc"; echo -e "\n"
  check_service "networker"; echo -e "\n"
  check_service "illumio-ven"; echo -e "\n"
  check_service "controlm-agent"; echo -e "\n"
  check_service "connectdirect"; echo -e "\n"
  
  # === SECURITY ===
  echo -e "\n=== SECURITY ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_selinux; echo -e "\n"
  check_ssh_config; echo -e "\n"
  
  # === RHEL CLUSTER CHECKS ===
  echo -e "\n=== RHEL CLUSTER CHECKS ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_rhel_cluster; echo -e "\n"
  check_corosync; echo -e "\n"
  check_fencing; echo -e "\n"
  
  # === NFS CHECKS ===
  echo -e "\n=== NFS CHECKS ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_nfs_fstab; echo -e "\n"
  check_nfs_mounts; echo -e "\n"
  check_nfs_services; echo -e "\n"

  # === SIMPLIFIED DATABASE SERVER DETECTION ===
  echo -e "\n=== DATABASE SERVER DETECTION ==="
  echo -e "-----------------------------------------------------------------    -----------------------------------------    --------------------------------------------------------------------------------"
  check_postgres_server; echo -e "\n"
  check_mongodb_server; echo -e "\n"
  check_other_db_servers; echo -e "\n"
}

echo -e "\nRHEL 8 Prechecks Report with Cluster, NFS & Database Server Detection - $(date)"
