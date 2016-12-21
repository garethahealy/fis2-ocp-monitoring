#!/usr/bin/env bash

echo "Deploying code signing key..."

cd ./.travis

openssl aes-256-cbc -K $encrypted_d9fa33f693e8_key -iv $encrypted_d9fa33f693e8_iv -in codesigning.asc.enc -out codesigning.asc -d
gpg --fast-import codesigning.asc

cd ../
