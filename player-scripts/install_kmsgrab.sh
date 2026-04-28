#!/bin/bash
set -e

sudo apt install -y cmake libdrm-dev zlib1g-dev libpng-dev

git clone https://github.com/pcercuei/kmsgrab
cd kmsgrab
mkdir -p build && cd build
cmake ..
make
sudo cp kmsgrab /usr/local/bin/

echo "sudo kmsgrab screenshot.png"