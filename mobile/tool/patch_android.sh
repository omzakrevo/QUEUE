#!/usr/bin/env sh
# Après `flutter create`, autorise le trafic HTTP en clair, l'accès à la synthèse vocale (annonces) (le serveur est sur le réseau local,
# sans HTTPS) et fixe le nom affiché. À exécuter depuis mobile/.
set -e
M=android/app/src/main/AndroidManifest.xml
grep -q usesCleartextTraffic "$M" || sed -i 's/<application/<application android:usesCleartextTraffic="true"/' "$M"
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
grep -q TTS_SERVICE "$M" || sed -i 's#<application#<queries>\n        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>\n    </queries>\n    <application#' "$M"
sed -i 's/android:label="[^"]*"/android:label="OMZA QUEUE"/' "$M"
