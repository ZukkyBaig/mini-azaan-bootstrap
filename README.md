# Mini Azaan Bootstrap

Run this on a fresh Raspberry Pi OS Lite (with SSH + WiFi enabled):

curl -fsSL https://raw.githubusercontent.com/zukkybaig/mini-azaan-bootstrap/main/install.sh | sudo bash -s -- -r git@github.com:zukkybaig/mini-azaan.git -b main

The installer will:
- Generate an SSH deploy key
- Prompt you to add it to the private repo
- Install and start the device service
