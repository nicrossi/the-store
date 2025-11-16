#!/bin/bash
set -e

if ! command -v kumactl &> /dev/null; then
  echo "Downloading kumactl..."
  curl -L https://kuma.io/installer.sh | VERSION=2.7.0 bash -

  mkdir -p $HOME/kuma-2.7.0
  mv /home/cristiantepedino/GolandProjects/tpe-redes/kuma-2.7.0/* $HOME/kuma-2.7.0/
  echo 'export PATH="$PATH:$HOME/kuma-2.7.0/bin"' >> ~/.bashrc
  source ~/.bashrc

  echo "Kumactl was successfully installed"
else
  echo "Kumactl already installed"
fi