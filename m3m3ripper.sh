#!/bin/bash
# NVIDIA GPU Overclocking Script for Linux (e.g., Ubuntu)
# This script enables persistence mode, adjusts power limits, overclocks core/memory, and sets fan speed.
# It includes safety checks and can revert to default settings.
# **Use at your own risk. Monitor temperatures and stability when overclocking.**

# ----------------------------- 
# User-configurable settings: adjust these values as needed for your GPU
# -----------------------------
CORE_OFFSET=100      # GPU core clock offset in MHz (positive to overclock, negative to underclock). Default +100 MHz.
MEM_OFFSET=200       # GPU memory clock offset in MHz (positive to overclock). Default +200 MHz.
# Note: The memory offset will be doubled internally because NVIDIA expects half the effective rate&#8203;:contentReference[oaicite:7]{index=7}.
POWER_LIMIT=""       # Power limit in watts. If blank or 0, the script will use the maximum allowed for your GPU.
FAN_SPEED=70         # Fan speed in percent (0-100) if manual control is supported. Default 70%. Ignored if not supported.

# ----------------------------- 
# No user configuration needed below this line 
# -----------------------------

# Safety: Do not allow offsets beyond safe ranges (driver typically limits to -1000 to +1000 for core, and -2000 to +6000 for memory)
if [ $CORE_OFFSET -gt 1000 ]; then CORE_OFFSET=1000; fi
if [ $CORE_OFFSET -lt -1000 ]; then CORE_OFFSET=-1000; fi
if [ $MEM_OFFSET -gt 6000 ]; then MEM_OFFSET=6000; fi
if [ $MEM_OFFSET -lt -2000 ]; then MEM_OFFSET=-2000; fi

# Determine if we are reverting settings
ACTION="apply"
if [ "$1" = "revert" ] || [ "$1" = "reset" ]; then
    ACTION="revert"
fi

# If running under sudo, ensure DISPLAY is set (for nvidia-settings)
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:0   # fallback to display :0 if not set
fi

# If not root, prepare to use sudo for commands that require root (like nvidia-smi for power limit)
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# Query default and maximum power limits (no sudo needed for querying on most systems)
DEFAULT_PL=$($SUDO nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits -i 0 2>/dev/null)
MAX_PL=$($SUDO nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits -i 0 2>/dev/null)

# Revert settings to defaults
if [ "$ACTION" = "revert" ]; then
    echo "Reverting GPU settings to default..."

    # 1. Disable persistence mode (allow GPU to idle off if no processes)
    $SUDO nvidia-smi -pm 0

    # 2. Reset power limit to default if available
    if [[ -n "$DEFAULT_PL" ]]; then
        $SUDO nvidia-smi -i 0 -pl $DEFAULT_PL
    fi

    # 3. Restore automatic fan control and reset fan speed (if applicable)
    nvidia-settings -a "[gpu:0]/GPUFanControlState=0" >/dev/null 2>&1

    # 4. Restore default PowerMizer mode (adaptive auto)
    nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0" >/dev/null 2>&1

    # 5. Remove any manual overclock offsets (set them to 0)
    nvidia-settings -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=0" >/dev/null 2>&1
    nvidia-settings -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=0" >/dev/null 2>&1

    echo "Revert complete. GPU settings should now be at stock defaults. You may also reboot to ensure all settings are reset."
    exit 0
fi

# If applying overclock
echo "Applying overclock settings..."

# 1. Enable persistence mode to keep GPU driver loaded and maintain settings&#8203;:contentReference[oaicite:8]{index=8}
#    (This helps settings like power limit persist even when no GUI apps are running)
$SUDO nvidia-smi -pm 1 || echo "Warning: Could not enable persistence mode (check driver installation)."

# 2. Set GPU power limit for optimal performance (if a custom limit is given or use max if not)&#8203;:contentReference[oaicite:9]{index=9}
if [[ -z "$POWER_LIMIT" || "$POWER_LIMIT" -le 0 ]]; then
    # Use maximum allowed power limit if not specified
    if [[ -n "$MAX_PL" ]]; then
        POWER_LIMIT=$MAX_PL
    fi
fi
# Ensure requested power limit does not exceed hardware max
if [[ -n "$MAX_PL" && -n "$POWER_LIMIT" ]]; then
    # Strip decimals if any for comparison
    MAX_PL_INT=${MAX_PL%%.*}
    REQ_PL_INT=${POWER_LIMIT%%.*}
    if (( REQ_PL_INT > MAX_PL_INT )); then
        echo "Requested power limit (${POWER_LIMIT}W) is above max allowed (${MAX_PL}W). Capping to ${MAX_PL}W."
        POWER_LIMIT=$MAX_PL
    fi
fi
if [[ -n "$POWER_LIMIT" && "$POWER_LIMIT" != "0" ]]; then
    $SUDO nvidia-smi -i 0 -pl $POWER_LIMIT || echo "Warning: Failed to set power limit (requires root and support)."
    echo "Power limit set to ${POWER_LIMIT}W."
fi

# 3. Set GPU to Prefer Maximum Performance mode so it doesn't downclock (Powermizer mode)&#8203;:contentReference[oaicite:10]{index=10}
nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" >/dev/null 2>&1 || echo "Warning: Could not set PowerMizer performance mode."

# 4. Enable manual fan control (if supported) and set fan speed&#8203;:contentReference[oaicite:11]{index=11}
if [[ $FAN_SPEED -ge 0 && $FAN_SPEED -le 100 ]]; then
    nvidia-settings -a "[gpu:0]/GPUFanControlState=1" >/dev/null 2>&1 && \
    nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=$FAN_SPEED" >/dev/null 2>&1 || \
    echo "Note: Fan speed control not supported on this GPU or permission denied."
    echo "Fan control enabled at ${FAN_SPEED}% (if supported)."
fi

# 5. Apply core and memory overclock offsets using nvidia-settings
#    We use the "AllPerformanceLevels" attributes to apply to all P-states&#8203;:contentReference[oaicite:12]{index=12}.
ACTUAL_MEM_OFFSET=$(( MEM_OFFSET * 2 ))   # double the memory offset for effective value&#8203;:contentReference[oaicite:13]{index=13}
# Apply GPU core clock offset
nvidia-settings -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=$CORE_OFFSET" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Failed to set GPU core clock offset. Ensure Coolbits is enabled for overclocking&#8203;:contentReference[oaicite:14]{index=14}."
else
    echo "GPU core clock offset set to +${CORE_OFFSET} MHz."
fi
# Apply GPU memory clock offset
nvidia-settings -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=$ACTUAL_MEM_OFFSET" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Failed to set GPU memory offset. Ensure Coolbits is enabled and value is within allowed range."
else
    echo "GPU memory clock offset set to +${MEM_OFFSET} MHz (effective)."
fi

echo "Overclock settings applied. Please monitor GPU temperatures and stability."
echo "To revert to default settings, run: $0 revert"
