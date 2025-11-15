#!/bin/bash
set -e

if ! command -v kumactl &> /dev/null; then
  echo "Downloading kumactl..."
  curl -L https://kuma.io/installer.sh | VERSION=2.7.0 bash -
  export PATH=$PATH:$HOME/kuma-2.7.0/bin
  echo "Kumactl was successfully installed"
else
  echo "Kumactl already installed"
fi