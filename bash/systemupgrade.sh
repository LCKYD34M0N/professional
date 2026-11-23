#!/usr/bin/env bash

# ANSI Color Codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color


# Array to track failed steps
FAILED_STEPS=()

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Ensure script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script with sudo or as root."
    exit 1
fi

echo -e "${BOLD}${CYAN}==============================================${NC}"
echo -e "${BOLD}${CYAN}      CUSTOM SYSTEM UPGRADE SUITE             ${NC}"
echo -e "${BOLD}${CYAN}==============================================${NC}"

# ---------------------------------------------------------
# Step 1: Update Repositories
# ---------------------------------------------------------
log_info "[1/5] Updating APT package repositories..."
if apt-get update -y; then
    log_success "Repository lists updated successfully."
else
    log_error "Repository update failed! Aborting script to maintain system safety."
    exit 1
fi

# ---------------------------------------------------------
# Step 2: Update Flatpaks
# ---------------------------------------------------------
log_info "[2/5] Checking Flatpak updates..."
if command -v flatpak &> /dev/null; then
    echo -e "\n${BOLD}Available Flatpak Updates:${NC}"
    flatpak remote-updates --columns=application,name,version
    echo ""
    read -p "Do you want to proceed with Flatpak upgrades (y/N)? " PROMPT_RESPONSE
    if [[ $PROMPT_RESPONSE =~ ^[Yy]$ ]]; then
        if ! flatpak update -y && flatpak install -y flathub org.purebrowser.PureBrowser; then
            log_error "Flatpak updates encountered errors."
            FAILED_STEPS+=("Flatpak Updates")
        else
            log_success "Flatpaks updated successfully."
        fi
    else
        log_warn "Flatpak upgrades skipped by user."
    fi
else
    log_warn "Flatpak is not installed. Skipping..."
fi

# ---------------------------------------------------------
# Step 3: System Updates
# ---------------------------------------------------------
log_info "[3/5] Checking system updates..."
echo -e "\n${BOLD}Available System Upgrades:${NC}"
apt list --upgradable
echo ""
read -p "Do you want to proceed with system updates (y/N)? " PROMPT_RESPONSE
if [[ $PROMPT_RESPONSE =~ ^[Yy]$ ]]; then
    if ! apt-get dist-upgrade -y; then
        log_error "System updates encountered errors."
        FAILED_STEPS+=("Full System Updates (dist-upgrade)")
    else
        log_success "System updates completed."
    fi
    
    log_info "Cleaning up unneeded dependencies..."
    apt-get autoremove -y
    apt-get autoclean -y
else
    log_warn "System updates skipped by user."
fi

# ---------------------------------------------------------
# Step 4: Verify & Repair NVIDIA / DKMS Modules
# ---------------------------------------------------------
log_info "[4/5] Checking NVIDIA driver and kernel module health..."
if dpkg -l | grep -q nvidia-driver; then
    CURRENT_KERNEL=$(uname -r)
    log_info "Active kernel: $CURRENT_KERNEL"
    
    # Check if the nvidia module is built/available for the current kernel
    if ! modinfo -k "$CURRENT_KERNEL" nvidia &> /dev/null; then
        log_warn "NVIDIA kernel module missing for $CURRENT_KERNEL! Attempting automatic rebuild..."
        
        # Ensure kernel headers are present
        apt-get install -y linux-headers-$(uname -r | sed 's/[^-]*-[^-]*-//') linux-headers-amd64
        
        # Trigger DKMS re-trigger or module reconfigure
        if dpkg -l | grep -q nvidia-dkms; then
            dpkg-reconfigure nvidia-dkms
        else
            dkms autoinstall
        fi
        
        # Verify again
        if modinfo -k "$CURRENT_KERNEL" nvidia &> /dev/null; then
            log_success "NVIDIA driver successfully rebuilt and signed for $CURRENT_KERNEL."
        else
            log_error "NVIDIA driver module rebuild failed."
            FAILED_STEPS+=("NVIDIA Driver Rebuild")
        fi
    else
        log_success "NVIDIA driver module is present and valid for the current kernel."
    fi
else
    log_info "NVIDIA drivers not detected on this system. Skipping check."
fi

# ---------------------------------------------------------
# Step 5: Check for Reboot Requirement
# ---------------------------------------------------------
log_info "[5/5] Checking system reboot state..."
REBOOT_NEEDED=false
if [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
fi

# ---------------------------------------------------------
# Final Notification & Status Summary (Terminal Only)
# ---------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}==============================================${NC}"
echo -e "${BOLD}${CYAN}            EXECUTION SUMMARY                 ${NC}"
echo -e "${BOLD}${CYAN}==============================================${NC}"

# Installation Status Bar Display
echo -n "Installation Progress: ["
if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    echo -e "${GREEN}██████████████████████████████${NC}] 100% SUCCESS"
else
    echo -e "${YELLOW}████████████████░░░░░░░░░░░░░░${NC}] COMPLETED WITH ERRORS"
fi

# Terminal Notification for Failures
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    for step in "${FAILED_STEPS[@]}"; do
        echo -e " ${RED}-${NC} $step"
    done
else
    echo -e "\n${GREEN}${BOLD}NOTIFICATION:${NC} All update tasks ran smoothly without failures."
fi

# Reboot Status Report
if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "\n${YELLOW}${BOLD}REBOOT STATUS:${NC} A system reboot IS required to apply kernel or core library updates."
else
    echo -e "\n${GREEN}${BOLD}REBOOT STATUS:${NC} No reboot is required."
fi

echo -e "${BOLD}${CYAN}==============================================${NC}"