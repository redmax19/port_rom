#!/bin/bash

# Check if a file argument is provided
if [[ "$#" -eq 0 ]]; then
    echo "ERROR: No File Specified!" && exit 1
fi

FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: File '$FILE' does not exist!" && exit 1
fi

# Query GoFile API to find the best server for upload
SERVER_RESPONSE=$(curl -s https://api.gofile.io/servers)
SERVER=$(echo "$SERVER_RESPONSE" | jq -r '.data.servers[0].name // empty')

if [[ -z "$SERVER" ]]; then
    echo "ERROR: Failed to fetch GoFile server. Response was:"
    echo "$SERVER_RESPONSE"
    exit 1
fi

# Upload the file to GoFile
# Running curl silently (-sS) ensures progress text won't pollute jq
UPLOAD_RESPONSE=$(curl -sS -F "file=@$FILE" "https://${SERVER}.gofile.io/contents/uploadfile")

# Parse JSON response safely
LINK=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.downloadPage // empty')

if [[ -n "$LINK" ]]; then
    echo "Uploaded successfully!"
    echo "$LINK"
else
    echo "ERROR: Upload failed. API Response:"
    echo "$UPLOAD_RESPONSE"
    exit 1
fi
