#!/bin/bash

# Function to print the data into table format.
function printTable() {
    local -r delimiter="${1}"
    local -r data="$(removeEmptyLines "${2}")"
    if [[ "${delimiter}" != '' && "$(isEmptyString "${data}")" = 'false' ]]
    then
        local -r numberOfLines="$(wc -l <<< "${data}")"
        if [[ "${numberOfLines}" -gt '0' ]]
        then
            local table=''
            local i=1
            for ((i = 1; i <= "${numberOfLines}"; i = i + 1))
            do
                local line=''
                line="$(sed "${i}q;d" <<< "${data}")"
                local numberOfColumns='0'
                numberOfColumns="$(awk -F "${delimiter}" '{print NF}' <<< "${line}")"
                # Add Line Delimiter
                if [[ "${i}" -eq '1' ]]
                then
                    table="${table}$(printf '%s#+' "$(repeatString '#+' "${numberOfColumns}")")"
                fi
                # Add Header Or Body
                table="${table}\n"
                local j=1
                for ((j = 1; j <= "${numberOfColumns}"; j = j + 1))
                do
                    table="${table}$(printf '#| %s' "$(cut -d "${delimiter}" -f "${j}" <<< "${line}")")"
                done
                table="${table}#|\n"
                # Add Line Delimiter
                if [[ "${i}" -eq '1' ]] || [[ "${numberOfLines}" -gt '1' && "${i}" -eq "${numberOfLines}" ]]
                then
                    table="${table}$(printf '%s#+' "$(repeatString '#+' "${numberOfColumns}")")"
                fi
            done
            if [[ "$(isEmptyString "${table}")" = 'false' ]]
            then
                echo -e "${table}" | column -s '#' -t | awk '/^\+/{gsub(" ", "-", $0)}1'
            fi
        fi
    fi
}

function removeEmptyLines() {
    local -r content="${1}"
    echo -e "${content}" | sed '/^\s*$/d'
}

function repeatString() {
    local -r string="${1}"
    local -r numberToRepeat="${2}"
    if [[ "${string}" != '' && "${numberToRepeat}" =~ ^[1-9][0-9]*$ ]]
    then
        local -r result="$(printf "%${numberToRepeat}s")"
        echo -e "${result// /${string}}"
    fi
}

function isEmptyString() {
    local -r string="${1}"
    if [[ "$(trimString "${string}")" = '' ]]
    then
        echo 'true' && return 0
    fi
    echo 'false' && return 1
}

function trimString() {
    local -r string="${1}"
    sed 's,^[[:blank:]]*,,' <<< "${string}" | sed 's,[[:blank:]]*$,,'
}

# Function to print error messages in red
print_error() {
    tput setaf 1 # Set text color to red
    echo "Error: $1"
    tput sgr0   # Reset text color
}

# Function to prompt for required details
prompt_for_input() {
    read -p "$1: " input_value
    if [[ -z "$input_value" ]]; then
        print_error "$2 cannot be empty!"
        exit 1
    fi
    echo "$input_value"
}

# Argument to control column limit
COLUMN_LIMIT=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --column-header) COLUMN_LIMIT="$2"; shift ;;
        *) print_error "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Prompt for MongoDB connection details
mongo_uri=$(prompt_for_input "Enter MongoDB URI (e.g., mongodb://user:pass@localhost:27017/dbname)" "MongoDB URI")

# Function to read a multi-line query from the user
echo "Enter your MongoDB query (e.g., db.collection.find({...})). Press Enter twice to execute the query:"

mongo_query=""
while IFS= read -r line; do
    # If the user hits Enter without typing anything, break the loop
    if [[ -z "$line" ]]; then
        break
    fi
    mongo_query+="$line "
done

if [[ -z "$mongo_query" ]]; then
    print_error "Query cannot be empty!"
    exit 1
fi

# Remove trailing semicolon if it exists using sed
mongo_query=$(echo "$mongo_query" | sed 's/;[[:space:]]*$//')

# Check if the query is using .find or .aggregate, and automatically wrap it with toArray()
if [[ "$mongo_query" == *".find("* || "$mongo_query" == *".aggregate("* ]]; then
    wrapped_query="print(JSON.stringify($mongo_query.toArray(), null, 2));"
else
    wrapped_query="print(JSON.stringify($mongo_query, null, 2));"
fi

# Save the wrapped query to a file for future use
query_file="mongo_query.txt"
echo "$wrapped_query" > "$query_file"
echo "Query wrapped and saved to $query_file"

# Run the wrapped query using mongosh
output=$(mongo "$mongo_uri" --eval "$wrapped_query" --quiet 2>&1)

# Check if there was an error
if [[ $? -ne 0 ]]; then
    print_error "Failed to run the query!"
    echo "$output"
    exit 1
fi

# Check if output is empty
if [[ -z "$output" ]]; then
    print_error "No data returned!"
    exit 1
fi

# Check if the output is valid JSON
if ! echo "$output" | jq empty > /dev/null 2>&1; then
    # Convert the output to a JSON array of strings if it's plain text
    print_error "Output is not valid JSON. Converting to JSON array."
    output=$(echo "$output" | jq -R -s -c 'split("\n")[:-1]')
fi

# Check if it's a simple list of strings and handle them without keys
if [[ "$output" == *"[\""* ]]; then
    echo "Detected a list of strings, printing them in table format."
    # Convert JSON array of strings to a table format
    json_array=$(echo "$output" | jq -r '.[]')  # Extract the strings from the JSON array

    # Prepare table headers and rows
    table_data="Data\n"
    while IFS= read -r line; do
        table_data+="$line\n"
    done <<< "$json_array"

    # Print the table using printTable function
    printTable ',' "$table_data"
else
    # Handle complex JSON with keys
    if [[ "$COLUMN_LIMIT" -gt 0 ]]; then
        echo "Limiting columns to $COLUMN_LIMIT"
        table_data=$(echo "$output" | jq -r "
            (.[0] | keys_unsorted | .[:$COLUMN_LIMIT]) as \$keys |       # Extract limited number of headers
            (\$keys | @tsv),                         # Print headers as tab-separated values (TSV)
            (.[] |                                  
              [.[\$keys[]] |                         # Iterate over the keys and print values for the limited columns
                if type == \"array\" or type == \"object\" then \"Nested\" else . end
              ] | @tsv)                             # Format the output as TSV for each row
        ")
    else
        # Print all columns if no limit is set
        table_data=$(echo "$output" | jq -r '
            (.[0] | keys_unsorted) as $keys |       # Extract headers (keys) from the first object
            ($keys | @tsv),                         # Print headers as tab-separated values (TSV)
            (.[] |                                  
              [.[$keys[]]] |                         # Iterate over the keys and print values
              if type == "array" or type == "object" then "Nested" else . end
              ] | @tsv)                             # Format the output as TSV for each row
        ')
    fi

    # Use printTable to format the output in table form
    printTable $'\t' "$table_data"
fi

# Success message
tput setaf 2 # Set text color to green
echo "Query executed successfully!"
tput sgr0   # Reset text color
