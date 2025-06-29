#!/bin/bash

set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 <table_path>"
    echo ""
    echo "Arguments:"
    echo "  table_path     Path to the Iceberg table (parent directory of 'metadata')"
    echo ""
    echo "Example:"
    echo "  $0 ./data/persistent/segfault_issue"
    echo ""
    echo "This will rewrite absolute paths to be relative to the given table path,"
    echo "keeping only the table-relative parts like 'data/...' and 'metadata/...'"
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    usage
fi

TABLE_PATH="$1"
NEW_BASE_PATH="$1"

# Validate paths
if [ ! -d "$TABLE_PATH" ]; then
    echo "Error: Table path '$TABLE_PATH' does not exist or is not a directory"
    exit 1
fi

if [ ! -d "$TABLE_PATH/metadata" ]; then
    echo "Error: '$TABLE_PATH/metadata' does not exist. This doesn't appear to be an Iceberg table."
    exit 1
fi

# Normalize table path to absolute path
TABLE_PATH_ABS=$(cd "$TABLE_PATH" && pwd)

# Check for CRC files that can interfere with Avro processing
if find "$TABLE_PATH" -name "*.crc" | grep -q .; then
    echo "Error: Found .crc files in the table directory. These can cause checksum errors with avro-tools."
    echo "Please delete all .crc files before running this script:"
    find "$TABLE_PATH" -name "*.crc"
    exit 1
fi

echo "Relativizing Iceberg table at: $TABLE_PATH_ABS"
echo "Using new base path: $NEW_BASE_PATH"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Set up cleanup trap
cleanup() {
    echo "Cleaning up temporary directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Create mirror directory structure in temp dir
mkdir -p "$TEMP_DIR/metadata"

# Function to relativize a path by extracting table-relative parts
relativize_path() {
    local abs_path="$1"
    local new_base="$2"
    
    # Extract the table-relative part (data/... or metadata/...)
    # Look for patterns like /some/path/to/table/data/... or /some/path/to/table/metadata/...
    if [[ "$abs_path" =~ .*/data/.* ]]; then
        # Extract everything from "/data/" onwards
        local relative_part="${abs_path##*/data/}"
        echo "$new_base/data/$relative_part"
    elif [[ "$abs_path" =~ .*/metadata/.* ]]; then
        # Extract everything from "/metadata/" onwards
        local relative_part="${abs_path##*/metadata/}"
        echo "$new_base/metadata/$relative_part"
    else
        # If it doesn't match expected patterns, try to make it relative to new base
        # This handles the table location itself
        echo "$new_base"
    fi
}

# Process JSON files
echo "Processing JSON metadata files..."
for json_file in "$TABLE_PATH/metadata"/*.json; do
    if [ -f "$json_file" ]; then
        filename=$(basename "$json_file")
        echo "  Processing $filename"
        
        # Use jq to rewrite paths
        jq --arg new_base_path "$NEW_BASE_PATH" '
            def relativize_path(path; new_base):
                if (path | test(".*/index/data/.*")) then
                    # Extract everything after "/index/" and prepend new base
                    (path | sub(".*?/index/"; "")) as $data_part |
                    new_base + "/" + $data_part
                elif (path | test(".*/index/metadata/.*")) then
                    # Extract everything after "/index/" and prepend new base
                    (path | sub(".*?/index/"; "")) as $metadata_part |
                    new_base + "/" + $metadata_part
                elif (path | test(".*/index$")) then
                    # This is the table location itself
                    new_base
                else
                    # Fallback: try to extract relative to any data/ or metadata/ pattern
                    if (path | test(".*/data/.*")) then
                        (path | sub(".*?/data/"; "")) as $data_part |
                        new_base + "/data/" + $data_part
                    elif (path | test(".*/metadata/.*")) then
                        (path | sub(".*?/metadata/"; "")) as $metadata_part |
                        new_base + "/metadata/" + $metadata_part
                    else
                        new_base
                    end
                end;
            
            # Relativize .location
            .location = relativize_path(.location; $new_base_path) |
            
            # Relativize .snapshots[].["manifest-list"]
            if .snapshots then
                .snapshots = (.snapshots | map(
                    if .["manifest-list"] then
                        .["manifest-list"] = relativize_path(.["manifest-list"]; $new_base_path)
                    else . end
                ))
            else . end |
            
            # Relativize .["metadata-log"].[].["metadata-file"]
            if .["metadata-log"] then
                .["metadata-log"] = (.["metadata-log"] | map(
                    if .["metadata-file"] then
                        .["metadata-file"] = relativize_path(.["metadata-file"]; $new_base_path)
                    else . end
                ))
            else . end
        ' "$json_file" > "$TEMP_DIR/metadata/$filename"
    fi
done

# Process Avro files
echo "Processing Avro metadata files..."
for avro_file in "$TABLE_PATH/metadata"/*.avro; do
    if [ -f "$avro_file" ]; then
        filename=$(basename "$avro_file")
        echo "  Processing $filename"
        
        # Get schema
        avro-tools getschema "$avro_file" > "$TEMP_DIR/${filename}.avsc" 2>/dev/null
        
        # Convert to JSON
        avro-tools tojson "$avro_file" > "$TEMP_DIR/${filename}.json" 2>/dev/null
        
        # Process the JSON based on file type
        if [[ "$filename" == snap-* ]]; then
            # For snap-*.avro files, rewrite manifest_path
            echo "    Rewriting manifest_path in $filename"
            jq --arg new_base_path "$NEW_BASE_PATH" '
                def relativize_path(path; new_base):
                    if (path | test(".*/index/data/.*")) then
                        # Extract everything after "/index/" and prepend new base
                        (path | sub(".*?/index/"; "")) as $data_part |
                        new_base + "/" + $data_part
                    elif (path | test(".*/index/metadata/.*")) then
                        # Extract everything after "/index/" and prepend new base
                        (path | sub(".*?/index/"; "")) as $metadata_part |
                        new_base + "/" + $metadata_part
                    elif (path | test(".*/index$")) then
                        # This is the table location itself
                        new_base
                    else
                        # Fallback: try to extract relative to any data/ or metadata/ pattern
                        if (path | test(".*/data/.*")) then
                            (path | sub(".*?/data/"; "")) as $data_part |
                            new_base + "/data/" + $data_part
                        elif (path | test(".*/metadata/.*")) then
                            (path | sub(".*?/metadata/"; "")) as $metadata_part |
                            new_base + "/metadata/" + $metadata_part
                        else
                            new_base
                        end
                    end;
                
                .manifest_path = relativize_path(.manifest_path; $new_base_path)
            ' "$TEMP_DIR/${filename}.json" > "$TEMP_DIR/${filename}.processed.json"
        else
            # For other .avro files, rewrite data_file.file_path
            echo "    Rewriting data_file.file_path in $filename"
            jq --arg new_base_path "$NEW_BASE_PATH" '
                def relativize_path(path; new_base):
                    if (path | test(".*/index/data/.*")) then
                        # Extract everything after "/index/" and prepend new base
                        (path | sub(".*?/index/"; "")) as $data_part |
                        new_base + "/" + $data_part
                    elif (path | test(".*/index/metadata/.*")) then
                        # Extract everything after "/index/" and prepend new base
                        (path | sub(".*?/index/"; "")) as $metadata_part |
                        new_base + "/" + $metadata_part
                    elif (path | test(".*/index$")) then
                        # This is the table location itself
                        new_base
                    else
                        # Fallback: try to extract relative to any data/ or metadata/ pattern
                        if (path | test(".*/data/.*")) then
                            (path | sub(".*?/data/"; "")) as $data_part |
                            new_base + "/data/" + $data_part
                        elif (path | test(".*/metadata/.*")) then
                            (path | sub(".*?/metadata/"; "")) as $metadata_part |
                            new_base + "/metadata/" + $metadata_part
                        else
                            new_base
                        end
                    end;
                
                if .data_file and .data_file.file_path then
                    .data_file.file_path = relativize_path(.data_file.file_path; $new_base_path)
                else . end
            ' "$TEMP_DIR/${filename}.json" > "$TEMP_DIR/${filename}.processed.json"
        fi
        
        # Convert back to Avro
        avro-tools fromjson --schema-file "$TEMP_DIR/${filename}.avsc" "$TEMP_DIR/${filename}.processed.json" > "$TEMP_DIR/metadata/$filename" 2>/dev/null
    fi
done

# Move processed files back to original location
echo "Moving processed files back to original location..."

# Backup original metadata directory by moving it
BACKUP_DIR="${TABLE_PATH}/metadata.backup.$(date +%Y%m%d_%H%M%S)"
echo "Creating backup at: $BACKUP_DIR"
mv "$TABLE_PATH/metadata" "$BACKUP_DIR"

# Move the new metadata directory into place
mv "$TEMP_DIR/metadata" "$TABLE_PATH/metadata"

echo "Successfully relativized Iceberg table metadata!"
echo "Original metadata backed up to: $BACKUP_DIR"
echo ""
echo "Summary of changes:"
echo "- Rewritten all absolute paths to use new base path: $NEW_BASE_PATH"
echo "- Modified JSON files: location, snapshots[].manifest-list, metadata-log[].metadata-file"
echo "- Modified Avro files: manifest_path (snap-*), data_file.file_path (others)"
