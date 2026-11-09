#!/usr/bin/env sh
# Copie les pages web du serveur (TV, QR, borne, agent) dans l'application : le téléphone les
# sert lui-même quand il joue le rôle de serveur. À relancer après toute modification de server/public.
set -e
cd "$(dirname "$0")/.."
rm -rf assets/web
mkdir -p assets/web
for d in tv ticket kiosk agent shared; do cp -r ../server/public/$d assets/web/$d; done
