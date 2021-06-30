#!/bin/bash
sudo apt update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="v1.20.6+rke2r1" sudo sh -
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service
