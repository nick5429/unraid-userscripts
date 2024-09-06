#!/bin/bash

# Plex server details
PLEX_URL="http://192.168.1.10:32400"
API_KEY=""

# Define the path mappings
declare -A path_map=(
    ["/Movies/"]="/mnt/user/Movies/"
    ["/TV-Kids/"]="/mnt/user/TV-Kids/"
    ["/TV-CurrentShows/"]="/mnt/user/TV-CurrentShows/"
    # Add more mappings as needed
)

# Define the video file extensions
video_ext='avi|mkv|mov|mp4|mpeg'

# Function to remap file paths
remap_path() {
    local original_path="$1"
    
    for prefix in "${!path_map[@]}"; do
        if [[ "$original_path" == "$prefix"* ]]; then
            # Replace the prefix with the mapped path
            echo "${original_path/$prefix/${path_map[$prefix]}}"
            return
        fi
    done
    
    # If no mapping found, return the original path
    echo "$original_path"
}

# Function to get "On Deck" items from Plex and process file paths
get_ondeck() {
    local plex_url="$1"
    local api_key="$2"
    
    # Query the On Deck list from Plex
    local plex_on_deck_url="$plex_url/library/onDeck?X-Plex-Token=$api_key"
    
    # Get the list of On Deck items (assumed response in XML format)
    local response=$(curl -s "$plex_on_deck_url")
    
    # Parse the XML response and extract the full file paths from <Part> tags
    local video_files=()
    while IFS= read -r line; do
        # Dynamically create a regular expression using the video_ext variable
        local file_path=$(echo "$line" | grep -oP "(?<=file=\")[^\"]+\.($video_ext)\"")
        if [[ -n "$file_path" ]]; then
            # Remove trailing quote that gets included
            file_path=$(echo "$file_path" | sed 's/"$//')
            
            # Remap the file path using the remap_path function
            local remapped_file_path=$(remap_path "$file_path")
            
            video_files+=("$remapped_file_path")
        fi
    done < <(echo "$response" | grep -oP '<Part[^>]*file="[^"]*"')

    # Output the array elements, one per line
    printf "%s\n" "${video_files[@]}"
}

# Get and print the remapped On Deck video files
echo "Remapped On Deck video files:"

# Capture the output of get_ondeck into an array called "ondeck_files"
mapfile -t ondeck_files < <(get_ondeck "$PLEX_URL" "$API_KEY")

# Print the remapped file paths
printf "%s\n" "${ondeck_files[@]}"
