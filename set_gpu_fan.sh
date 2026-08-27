#!/bin/bash

# Dynamically search all card slots (card0, card1, card2, etc.) for the hwmon folder
HWMON_PATH=$(ls -d /sys/class/drm/card*/device/hwmon/hwmon* 2>/dev/null | head -n 1)

# If that fails, check the alternate Linux kernel device path
if [ -z "$HWMON_PATH" ]; then
    HWMON_PATH=$(ls -d /sys/class/hwmon/hwmon*/device 2>/dev/null | grep -i "amdgpu" | head -n 1)
fi

# Fallback check if it still cannot find it
if [ -z "$HWMON_PATH" ] || [ ! -d "$HWMON_PATH" ]; then
    echo "Error: Could not find any AMD GPU system folders."
    echo "Please run: ls /sys/class/drm/ to see what hardware is listed."
    exit 1
fi

clear
echo "==============================================="
echo "       RX 570 FAN CONTROL PANEL"
echo "==============================================="
echo " Target Temperature: 60°C"
echo " Current GPU Temp: $(cat $HWMON_PATH/temp1_input 2>/dev/null | sed 's/...$//' || echo "Unknown")°C"
echo " Found hardware path at: $HWMON_PATH"
echo "-----------------------------------------------"
echo " 1) Quiet Mode   (~35% speed - IDLE/WEB)"
echo " 2) AI Workload  (~65% speed - TARGET FOR 60°C)"
echo " 3) Max Cooling  (100% speed - HEAVY LOAD)"
echo " 4) Custom Speed (Enter your own number)"
echo " 5) Reset GPU    (Return to Automatic Control)"
echo " 6) Exit"
echo "==============================================="
read -p "Select an option [1-6]: " OPTION

case $OPTION in
    1) SPEED=90 ;;
    2) SPEED=165 ;;
    3) SPEED=255 ;;
    4) echo ""
       read -p "Enter custom speed value (0 to 255): " SPEED ;;
    5) echo "Returning GPU to automatic system control..."
       echo "2" | sudo tee "$HWMON_PATH/pwm1_enable" > /dev/null
       echo "Done!"
       exit 0 ;;
    6) exit 0 ;;
    *) echo "Invalid selection." ; exit 1 ;;
esac

# Apply the chosen speed
echo "Switching GPU to manual control mode..."
echo "1" | sudo tee "$HWMON_PATH/pwm1_enable" > /dev/null
echo "Setting fan speed to $SPEED..."
echo "$SPEED" | sudo tee "$HWMON_PATH/pwm1" > /dev/null
echo "Success! Fan adjusted."

