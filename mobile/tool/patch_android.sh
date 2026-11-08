#!/usr/bin/env sh
# Après `flutter create`, autorise le trafic HTTP en clair (le serveur est sur le réseau local,
# sans HTTPS) et fixe le nom affiché. À exécuter depuis mobile/.
set -e
M=android/app/src/main/AndroidManifest.xml
grep -q usesCleartextTraffic "$M" || sed -i 's/<application/<application android:usesCleartextTraffic="true"/' "$M"
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
sed -i 's/android:label="[^"]*"/android:label="OMZA QUEUE"/' "$M"
