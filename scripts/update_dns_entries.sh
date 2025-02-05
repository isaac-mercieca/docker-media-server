#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Load environment variables from .env file (in the parent directory)
if [ -f "$SCRIPT_DIR/../.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/../.env" | xargs)
fi

# Ensure token is set
if [ -z "$TECHNITIUM_KEY" ]; then
    echo "❌ token not set! Please define it in the .env file."
    exit 1
fi

API_URL="http://localhost:5380/api/zones"
CREATE_URL="$API_URL/create"
ADD_URL="$API_URL/records/add"
LIST_URL="$API_URL/list"
DELETE_URL="$API_URL/delete"

# Get the machine's primary IP dynamically
DEFAULT_IP=$(hostname -I | awk '{print $1}')  # Gets first non-loopback IP

# Extract domains from Traefik's Docker labels
DOMAINS=$(docker inspect $(docker ps -q) | jq -r '.[].Config.Labels | with_entries(select(.value | match("Host";"i")))[]' | grep -oP '([a-zA-Z0-9.-]+\.[a-zA-Z]+)' | sort -u)

# Ensure we got domains
if [ -z "$DOMAINS" ]; then
    echo "❌ No domains found for Traefik!"
    exit 1
fi

# Step 1: List all zones and filter for primary zones
ZONE_LIST_RESPONSE=$(curl -s "$LIST_URL" -G \
    -d "pageNumber=1" \
    -d "zonesPerPage=500" \
    -d "token=$TECHNITIUM_KEY")

# Check if the request was successful
if [ $(echo "$ZONE_LIST_RESPONSE" | jq -r '.status') != "ok" ]; then
    echo "❌ Failed to fetch zone list!"
    exit 1
fi

# Extract all primary zones
PRIMARY_ZONES=$(echo "$ZONE_LIST_RESPONSE" | jq -r '.response.zones[] | select(.internal == false) | .name')

# Step 2: Delete all primary zones
for ZONE in $PRIMARY_ZONES; do
    DELETE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET $DELETE_URL \
         -d "zone=$ZONE" \
         -d "token=$TECHNITIUM_KEY")

    if [ "$DELETE_RESPONSE" -eq 200 ]; then
        echo "✅ Zone $ZONE deleted successfully."
    else
        echo "❌ Failed to delete zone $ZONE. HTTP Status: $DELETE_RESPONSE"
    fi
done

# Step 3: Create the zone for each domain
for DOMAIN in $DOMAINS; do
    # Create Zone if it doesn't exist (with type Primary, catalog, and useSoaSerialDateScheme=false)
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$CREATE_URL" \
         -G -d "zone=$DOMAIN" \
         -d "type=Primary" \
         -d "catalog=" \
         -d "useSoaSerialDateScheme=false" \
         -d "token=$TECHNITIUM_KEY")

    # Check if the zone creation was successful
    if [ "$RESPONSE" -eq 200 ]; then
        echo "✅ Zone for $DOMAIN created successfully."
    else
        echo "❌ Failed to create zone for $DOMAIN. HTTP Status: $RESPONSE"
        continue
    fi

    # Step 4: Add A Record for the domain with the required parameters
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$ADD_URL" \
         -G -d "zone=$DOMAIN" \
         -d "domain=$DOMAIN" \
         -d "type=A" \
         -d "ttl=" \
         -d "overwrite=false" \
         -d "comments=" \
         -d "expiryTtl=" \
         -d "ipAddress=$DEFAULT_IP" \
         -d "ptr=false" \
         -d "createPtrZone=false" \
         -d "updateSvcbHints=false" \
         -d "token=$TECHNITIUM_KEY")

    # Check if the record addition was successful
    if [ "$RESPONSE" -eq 200 ]; then
        echo "✅ A Record added for $DOMAIN."
    else
        echo "❌ Failed to add A Record for $DOMAIN. HTTP Status: $RESPONSE"
    fi
done
