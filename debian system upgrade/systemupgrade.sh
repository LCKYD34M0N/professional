#THIS IS USED FOR DEBIAN SYSTEMS ONLY!!!
#!/usr/bin/env bash

# Ensure /sbin and /usr/sbin are in PATH for tools like modinfo and dkms
export PATH="$PATH:/sbin:/usr/sbin"

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
echo -e "${BOLD}${CYAN}      CUSTOM SYSTEM UPGRADE SUITE${NC}"
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
    FLATPAK_UPDATES=$(flatpak remote-ls --updates --columns=application,name,version)
    if [ -z "$FLATPAK_UPDATES" ]; then
        echo "No Flatpak updates available."
    else
        echo "$FLATPAK_UPDATES"
    fi
    echo ""
    read -p "Do you want to proceed with Flatpak upgrades (y/N)? " PROMPT_RESPONSE
    if [[ $PROMPT_RESPONSE =~ ^[Yy]$ ]]; then
        if ! flatpak update -y; then
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
UPGRADABLES=$(apt list --upgradable 2>/dev/null | grep -v "Listing...")
if [ -z "$UPGRADABLES" ]; then
    echo "No system updates available."
else
    echo "$UPGRADABLES"
fi
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
# Step 4: Verify & Repair NVIDIA / DKMS / Secure Boot MOK
# ---------------------------------------------------------
log_info "[4/5] NVIDIA driver and DKMS check..."
if dpkg -l | grep -qE '^ii\s+nvidia-driver'; then
    echo -e "\n${BOLD}NVIDIA Driver & Kernel Module Sync:${NC}"
    echo "Active kernel: $(uname -r)"
    read -p "Do you want to check and sync NVIDIA drivers/DKMS modules (y/N)? " PROMPT_RESPONSE
    
    if [[ $PROMPT_RESPONSE =~ ^[Yy]$ ]]; then
        CURRENT_KERNEL=$(uname -r)
        
        if modinfo -k "$CURRENT_KERNEL" nvidia-current &> /dev/null \vert{}\vert{} modinfo -k "$CURRENT_KERNEL" nvidia &> /dev/null; then
            log_success "NVIDIA module verified for active kernel $CURRENT_KERNEL."
        else
            log_warn "NVIDIA kernel module missing for $CURRENT_KERNEL! Attempting automatic rebuild..."
            
            apt-get install -y linux-headers-amd64 "linux-headers-$CURRENT_KERNEL" 2>/dev/null || true

            if dpkg -l | grep -qE '^ii\s+nvidia-kernel-dkms'; then
                dpkg-reconfigure nvidia-kernel-dkms
            elif command -v dkms &> /dev/null; then
                dkms autoinstall
            fi

            if modinfo -k "$CURRENT_KERNEL" nvidia-current &> /dev/null \vert{}\vert{} modinfo -k "$CURRENT_KERNEL" nvidia &> /dev/null; then
                log_success "NVIDIA driver successfully rebuilt and signed for $CURRENT_KERNEL."
            else
                log_error "NVIDIA driver module rebuild failed."
                FAILED_STEPS+=("NVIDIA Driver Rebuild")
            fi
        fi

        # Check Secure Boot MOK key status if mokutil is available
        if command -v mokutil &> /dev/null; then
            if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
                MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
                if [ -f "$MOK_CERT" ]; then
                    if mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -qi "already enrolled"; then
                        log_success "Secure Boot is enabled and Debian DKMS MOK key is enrolled."
                    else
                        log_warn "Secure Boot MOK key ($MOK_CERT) is NOT enrolled! Enrolling now..."
                        if ! mokutil --import "$MOK_CERT"; then
                            log_error "Failed to stage MOK key enrollment."
                            FAILED_STEPS+=("MOK Key Enrollment")
                        fi
                    fi
                fi
            fi
        fi
    else
        log_warn "NVIDIA check skipped by user."
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

LATEST_KERNEL=$(ls -1 /lib/modules | sort -V | tail -n 1)
if [ -n "$LATEST_KERNEL" ] && [ "$LATEST_KERNEL" != "$(uname -r)" ]; then
    REBOOT_NEEDED=true
fi

# ---------------------------------------------------------
# Final Notification & Status Summary (Terminal Only)
# ---------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}==============================================${NC}"
echo -e "${BOLD}${CYAN}            EXECUTION SUMMARY${NC}"
echo -e "${BOLD}${CYAN}==============================================${NC}"

# Installation Status Bar Display
echo -n "Installation Progress: ["
if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    echo -e "${GREEN}██████████████████████████████${NC}] 100% SUCCESS"
else
    echo -e "${YELLOW}████████████████░░░░░░░░░░░░░░${NC}] COMP"
fi

# Reboot Status Report
if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "\n${YELLOW}${BOLD}REBOOT STATUS:${NC} A system reboot IS required to apply kernel or core library updates."
else
    echo -e "\n${GREEN}${BOLD}REBOOT STATUS:${NC} No reboot is required."
fi

echo -e "${BOLD}${CYAN}==============================================${NC}"
