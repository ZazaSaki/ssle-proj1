#!/bin/bash
# Threat 3 (C2) — install Metasploit on the Kali metasploit-container. Run INSIDE it.
# Guide 8 https apt-sources fix, then metasploit-framework.
set -e
sed -i 's|http://kali.download/kali|https://kali.download/kali|g; s|http://http.kali.org/kali|https://http.kali.org/kali|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
apt-get clean
rm -rf /var/lib/apt/lists/*
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --fix-missing metasploit-framework >/dev/null
echo "msfvenom: $(command -v msfvenom); msfconsole: $(command -v msfconsole)"
msfvenom --version 2>/dev/null | head -1 || true
