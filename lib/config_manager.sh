#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Configuration Management Library
# Handles Nacos configuration, datasource setup, and security settings

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ============================================================================
# Global Configuration Paths
# ============================================================================

# Use environment variable if set, otherwise use default
DEFAULT_DATASOURCE_CONFIG="${DEFAULT_DATASOURCE_CONFIG:-$HOME/ai-infra/nacos/default.properties}"

# ============================================================================
# Datasource Configuration
# ============================================================================

# Load default datasource configuration
# Returns: path to default datasource file or empty string
load_default_datasource_config() {
    # Check if default datasource exists and contains database configuration
    if [ -f "$DEFAULT_DATASOURCE_CONFIG" ] && [ -s "$DEFAULT_DATASOURCE_CONFIG" ]; then
        # Check if default config contains actual database configuration
        if grep -v '^[[:space:]]*#' "$DEFAULT_DATASOURCE_CONFIG" | \
           grep -v '^[[:space:]]*$' | \
           grep -qE '^(spring\.(datasource|sql\.init)\.platform|db\.num)'; then
            echo "$DEFAULT_DATASOURCE_CONFIG"
            return 0
        fi
    fi
    
    # No valid datasource configuration found
    echo ""
    return 1
}

# Apply datasource configuration to node
# Parameters: config_file, datasource_file
# Returns: 0 on success, 1 on failure
apply_datasource_config() {
    local config_file=$1
    local datasource_file=$2
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Check if datasource file exists and has valid configuration
    if [ -n "$datasource_file" ] && [ -f "$datasource_file" ] && [ -s "$datasource_file" ]; then
        if grep -v '^[[:space:]]*#' "$datasource_file" | \
           grep -v '^[[:space:]]*$' | \
           grep -qE '^(spring\.(datasource|sql\.init)\.platform|db\.num)'; then
            
            # Read datasource properties and apply them
            while IFS='=' read -r key value; do
                # Skip comments and empty lines
                [[ "$key" =~ ^#.*$ ]] && continue
                [[ -z "$key" ]] && continue
                
                # Trim whitespace
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs)
                
                update_config_property "$config_file" "$key" "$value"
            done < "$datasource_file"
            
            return 0
        fi
    fi
    
    # No external database, use Derby (for cluster mode, must explicitly set)
    # For standalone mode, Derby is the default
    return 1
}

# Configure datasource interactively
# Parameters: [config_file] - Optional path to config file (default: DEFAULT_DATASOURCE_CONFIG)
# Returns: 0 on success, 1 on failure
configure_datasource_interactive() {
    local config_file="${1:-$DEFAULT_DATASOURCE_CONFIG}"

    print_info ""
    print_info "========================================"
    print_info "External Datasource Configuration"
    print_info "========================================"
    echo ""
    echo "This will create a global datasource configuration that will be"
    echo "used by all future Nacos installations (standalone or cluster)."
    echo ""
    echo "Supported databases: MySQL, PostgreSQL"
    echo ""

    # Check if config already exists
    if [ -f "$config_file" ] && [ -s "$config_file" ]; then
        print_warn "Existing datasource configuration found at:"
        print_warn "  $config_file"
        echo ""
        read -p "Overwrite existing configuration? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled"
            return 1
        fi
        echo ""
    fi

    # Database Type
    echo "Step 1/6: Database Type"
    echo "  1) MySQL"
    echo "  2) PostgreSQL"
    echo ""
    while true; do
        read -p "Select database type (1-2): " db_type_choice
        case $db_type_choice in
            1) db_platform="mysql"; break ;;
            2) db_platform="postgresql"; break ;;
            *) echo "Invalid choice. Please enter 1 or 2." ;;
        esac
    done
    echo ""

    # Database Host
    echo "Step 2/6: Database Host"
    read -p "Enter database host (default: localhost): " db_host
    db_host=${db_host:-localhost}
    echo ""

    # Database Port
    echo "Step 3/6: Database Port"
    local default_port
    if [ "$db_platform" = "mysql" ]; then
        default_port=3306
    else
        default_port=5432
    fi
    read -p "Enter database port (default: $default_port): " db_port
    db_port=${db_port:-$default_port}
    echo ""

    # Database Name
    echo "Step 4/6: Database Name"
    read -p "Enter database name (default: nacos): " db_name
    db_name=${db_name:-nacos}
    echo ""

    # Database User
    echo "Step 5/6: Database User"
    read -p "Enter database username: " db_user
    while [ -z "$db_user" ]; do
        echo "Username cannot be empty"
        read -p "Enter database username: " db_user
    done
    echo ""

    # Database Password
    echo "Step 6/6: Database Password"
    read -s -p "Enter database password: " db_password
    echo ""
    while [ -z "$db_password" ]; do
        echo "Password cannot be empty"
        read -s -p "Enter database password: " db_password
        echo ""
    done
    echo ""

    # Construct database URL
    local db_url
    if [ "$db_platform" = "mysql" ]; then
        db_url="jdbc:mysql://${db_host}:${db_port}/${db_name}?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true"
    else
        db_url="jdbc:postgresql://${db_host}:${db_port}/${db_name}?currentSchema=public"
    fi

    # Create directory if not exists
    local datasource_dir=$(dirname "$config_file")
    if ! mkdir -p "$datasource_dir" 2>/dev/null; then
        print_error "Cannot create directory: $datasource_dir"
        print_error "Please ensure you have write permissions or run with appropriate privileges"
        return 1
    fi

    # Write configuration
    if ! cat > "$config_file" 2>/dev/null << EOF
# Nacos External Datasource Configuration
# Auto-generated on $(date)

# Database platform (mysql or postgresql)
spring.sql.init.platform=$db_platform

# Database connection pool size
db.num=1

# Database connection URL
db.url.0=$db_url

# Database credentials
db.user.0=$db_user
db.password.0=$db_password

# Connection pool configuration
db.pool.config.connectionTimeout=30000
db.pool.config.validationTimeout=10000
db.pool.config.maximumPoolSize=20
db.pool.config.minimumIdle=2
EOF
    then
        print_error "Cannot write to file: $config_file"
        print_error "Please check file permissions"
        return 1
    fi

    echo ""
    print_info "Datasource configuration saved to:"
    print_info "  $config_file"
    echo ""
    print_info "Configuration Summary:"
    echo "  Platform:  $db_platform"
    echo "  Host:      $db_host"
    echo "  Port:      $db_port"
    echo "  Database:  $db_name"
    echo "  User:      $db_user"
    echo ""
    print_info "This configuration will be used by all future Nacos installations."
    print_warn "Make sure the database exists and is accessible before installing Nacos."
    echo ""

    # Provide SQL initialization hint
    if [ "$db_platform" = "mysql" ]; then
        print_info "To initialize the database schema, run:"
        echo "  mysql -h$db_host -P$db_port -u$db_user -p$db_password $db_name < \$NACOS_HOME/conf/mysql-schema.sql"
    else
        print_info "To initialize the database schema, run:"
        echo "  psql -h$db_host -p$db_port -U$db_user -d$db_name -f \$NACOS_HOME/conf/postgresql-schema.sql"
    fi
    echo ""

    return 0
}

# Resolve config file path from config name
# Parameters: config_name - Config name (e.g., "prod", "default")
# Returns: full path to config file
_resolve_config_path() {
    local config_name="$1"
    if [ "$config_name" = "default" ]; then
        echo "$DEFAULT_DATASOURCE_CONFIG"
    else
        echo "$HOME/ai-infra/nacos/${config_name}.properties"
    fi
}

# Edit datasource configuration
# Parameters: [config_file] - Config name (e.g., "prod") or full path (default: DEFAULT_DATASOURCE_CONFIG, "default" for default path)
# Returns: 0 on success, 1 on failure
db_conf_edit() {
    local config_file="${1:-$DEFAULT_DATASOURCE_CONFIG}"
    # Handle "default" keyword
    if [ "$config_file" = "default" ]; then
        config_file="$DEFAULT_DATASOURCE_CONFIG"
    else
        config_file=$(_resolve_config_path "$config_file")
    fi
    configure_datasource_interactive "$config_file"
    return $?
}

# Show datasource configuration
# Parameters: [config_file] - Config name (e.g., "prod") or full path (default: DEFAULT_DATASOURCE_CONFIG, "default" for default path)
# Returns: 0 on success, 1 on failure
db_conf_show() {
    local config_file="${1:-$DEFAULT_DATASOURCE_CONFIG}"
    # Handle "default" keyword
    if [ "$config_file" = "default" ]; then
        config_file="$DEFAULT_DATASOURCE_CONFIG"
    else
        config_file=$(_resolve_config_path "$config_file")
    fi

    print_info ""
    print_info "========================================"
    print_info "Datasource Configuration"
    print_info "========================================"
    echo ""

    if [ ! -f "$config_file" ] || [ ! -s "$config_file" ]; then
        print_warn "No datasource configuration found at:"
        print_warn "  $config_file"
        echo ""
        print_info "To create a configuration, run:"
        print_info "  nacos-setup db-conf edit [FILE]"
        return 1
    fi

    print_info "File: $config_file"
    echo ""
    sed -E 's/^(db\.password\.([0-9]+)=).*/\1******/' "$config_file"
    echo ""
    return 0
}

# Configure Derby for cluster mode
# Parameters: config_file
configure_derby_for_cluster() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # For Derby in cluster mode, MUST explicitly set platform to 'derby'
    # spring.sql.init.platform is the new property (Spring Boot 3.x / Nacos 3.x)
    # spring.datasource.platform is the old property (Spring Boot 2.x / Nacos 2.x)
    update_config_property "$config_file" "spring.sql.init.platform" "derby"
    
    # Remove old property if exists (for compatibility)
    sed -i.bak '/^spring\.datasource\.platform=/d' "$config_file"
    
    # Remove any external database configurations that might exist
    sed -i.bak '/^db\.num=/d' "$config_file"
    sed -i.bak '/^db\.url/d' "$config_file"
    sed -i.bak '/^db\.user/d' "$config_file"
    sed -i.bak '/^db\.password/d' "$config_file"
    
    rm -f "$config_file.bak"
}

# ============================================================================
# Security Configuration
# ============================================================================

# Apply security configuration to node
# Parameters: config_file, token_secret, identity_key, identity_value
apply_security_config() {
    local config_file=$1
    local token_secret=$2
    local identity_key=$3
    local identity_value=$4
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Backup config file before modification
    backup_config_file "$config_file"
    
    # Enable authentication
    update_config_property "$config_file" "nacos.core.auth.enabled" "true"
    update_config_property "$config_file" "nacos.core.auth.plugin.nacos.token.secret.key" "$token_secret"
    update_config_property "$config_file" "nacos.core.auth.server.identity.key" "$identity_key"
    update_config_property "$config_file" "nacos.core.auth.server.identity.value" "$identity_value"
}

# Configure security for standalone mode
# Parameters: config_file, advanced_mode
# Returns: sets global variables TOKEN_SECRET, IDENTITY_KEY, IDENTITY_VALUE, NACOS_PASSWORD
configure_standalone_security() {
    local config_file=$1
    local advanced_mode=${2:-false}
    
    if [ "$advanced_mode" = false ]; then
        # Simplified mode: auto-generate all credentials
        TOKEN_SECRET=$(generate_secret_key)
        IDENTITY_KEY="nacos_identity_$(date +%s)"
        IDENTITY_VALUE=$(generate_secret_key | cut -c1-16)
        NACOS_PASSWORD=$(generate_password)
        
        if [ "$VERBOSE" = true ]; then
            echo "" >&2
            print_info "====================================" >&2
            print_info "Auto-Generated Security Configuration" >&2
            print_info "====================================" >&2
            echo "" >&2
            echo "JWT Token Secret Key:" >&2
            echo "  $TOKEN_SECRET" >&2
            echo "" >&2
            echo "Server Identity Key:" >&2
            echo "  $IDENTITY_KEY" >&2
            echo "" >&2
            echo "Server Identity Value:" >&2
            echo "  $IDENTITY_VALUE" >&2
            echo "" >&2
            print_info "These credentials will be automatically configured" >&2
            print_info "Admin password will be set after Nacos starts" >&2
        fi
    else
        # Advanced mode: interactive prompts
        print_info "" >&2
        print_info "====================================" >&2
        print_info "Security Configuration Required" >&2
        print_info "====================================" >&2
        echo "" >&2
        echo "Nacos requires security configuration for production use." >&2
        echo "" >&2
        
        # JWT Token Secret Key
        echo "Step 1/4: JWT Token Secret Key" >&2
        local auto_token=$(generate_secret_key)
        echo "Auto-generated value: $auto_token" >&2
        read -p "Enter JWT token secret key (press Enter to use auto-generated): " user_token
        TOKEN_SECRET=${user_token:-$auto_token}
        echo "" >&2
        
        # Server Identity Key
        echo "Step 2/4: Server Identity Key" >&2
        local auto_id_key="nacos_identity_$(date +%s)"
        echo "Auto-generated value: $auto_id_key" >&2
        read -p "Enter server identity key (press Enter to use auto-generated): " user_id_key
        IDENTITY_KEY=${user_id_key:-$auto_id_key}
        echo "" >&2
        
        # Server Identity Value
        echo "Step 3/4: Server Identity Value" >&2
        local auto_id_value=$(generate_secret_key | cut -c1-16)
        echo "Auto-generated value: $auto_id_value" >&2
        read -p "Enter server identity value (press Enter to use auto-generated): " user_id_value
        IDENTITY_VALUE=${user_id_value:-$auto_id_value}
        echo "" >&2
        
        # Admin Password
        echo "Step 4/4: Nacos Admin Password" >&2
        local auto_password=$(generate_password)
        echo "Auto-generated value: $auto_password" >&2
        read -p "Enter admin password (press Enter to use auto-generated): " user_password
        NACOS_PASSWORD=${user_password:-$auto_password}
        echo "" >&2
        
        print_info "Security keys configured successfully" >&2
    fi
    
    # Apply security configuration
    apply_security_config "$config_file" "$TOKEN_SECRET" "$IDENTITY_KEY" "$IDENTITY_VALUE"
}

# Configure security for cluster mode
# Parameters: cluster_dir, advanced_mode
# Returns: sets global variables and creates share.properties
configure_cluster_security() {
    local cluster_dir=$1
    local advanced_mode=${2:-false}
    local share_properties="$cluster_dir/share.properties"
    
    if [ "$VERBOSE" = true ]; then echo "" >&2; fi
    
    if [ "$advanced_mode" = false ]; then
        # Simplified mode: auto-generate all security credentials
        print_detail "Simplified mode: Auto-generating shared security keys for cluster..." >&2
        
        TOKEN_SECRET=$(generate_secret_key)
        IDENTITY_KEY="nacos_cluster_$(date +%s)"
        IDENTITY_VALUE=$(generate_secret_key | cut -c1-16)
        NACOS_PASSWORD=$(generate_password)
        
        if [ "$VERBOSE" = true ]; then
            echo "" >&2
            print_info "===========================================" >&2
            print_info "Auto-Generated Cluster Security Configuration" >&2
            print_info "===========================================" >&2
            echo "" >&2
            echo "JWT Token Secret Key:" >&2
            echo "  $TOKEN_SECRET" >&2
            echo "" >&2
            echo "Server Identity Key:" >&2
            echo "  $IDENTITY_KEY" >&2
            echo "" >&2
            echo "Server Identity Value:" >&2
            echo "  $IDENTITY_VALUE" >&2
            echo "" >&2
            print_info "These credentials will be shared across all cluster nodes" >&2
            print_info "Admin password will be set after cluster startup" >&2
            echo "" >&2
        fi
    else
        # Advanced mode: allow user to customize
        print_info "===========================================" >&2
        print_info "Cluster Security Configuration Required" >&2
        print_info "===========================================" >&2
        echo "" >&2
        echo "All nodes in the cluster must use the same security keys." >&2
        echo "" >&2
        
        # Similar interactive prompts as standalone
        echo "Step 1/4: JWT Token Secret Key" >&2
        local auto_token=$(generate_secret_key)
        echo "Auto-generated value: $auto_token" >&2
        read -p "Enter JWT token secret key (press Enter to use auto-generated): " user_token
        TOKEN_SECRET=${user_token:-$auto_token}
        echo "" >&2
        
        echo "Step 2/4: Server Identity Key" >&2
        local auto_id_key="nacos_cluster_$(date +%s)"
        echo "Auto-generated value: $auto_id_key" >&2
        read -p "Enter server identity key (press Enter to use auto-generated): " user_id_key
        IDENTITY_KEY=${user_id_key:-$auto_id_key}
        echo "" >&2
        
        echo "Step 3/4: Server Identity Value" >&2
        local auto_id_value=$(generate_secret_key | cut -c1-16)
        echo "Auto-generated value: $auto_id_value" >&2
        read -p "Enter server identity value (press Enter to use auto-generated): " user_id_value
        IDENTITY_VALUE=${user_id_value:-$auto_id_value}
        echo "" >&2
        
        echo "Step 4/4: Nacos Admin Password" >&2
        local auto_password=$(generate_password)
        echo "Auto-generated value: $auto_password" >&2
        read -p "Enter admin password (press Enter to use auto-generated): " user_password
        NACOS_PASSWORD=${user_password:-$auto_password}
        echo "" >&2
        
        print_info "Security keys configured successfully" >&2
        print_info "Admin password will be set after cluster startup" >&2
        echo "" >&2
    fi
    
    # Save shared security configuration to share.properties
    cat > "$share_properties" << EOF
# Nacos Cluster Shared Security Configuration
# Auto-generated on $(date)
# DO NOT modify these values unless you update ALL cluster nodes

# JWT Token Secret Key (Base64 encoded, 32+ characters before encoding)
nacos.core.auth.plugin.nacos.token.secret.key=$TOKEN_SECRET

# Server Identity Key (identifies the cluster)
nacos.core.auth.server.identity.key=$IDENTITY_KEY

# Server Identity Value (secret value for the identity key)
nacos.core.auth.server.identity.value=$IDENTITY_VALUE

# Admin Password (for 'nacos' user)
# Note: This is stored for reference only, actual password is set via API
admin.password=$NACOS_PASSWORD
EOF
    
    print_detail "Security configuration saved to: $share_properties" >&2
    if [ "$VERBOSE" = true ]; then echo "" >&2; fi
}

# ============================================================================
# Port Configuration
# ============================================================================

# Update port configuration in application.properties
# Parameters: config_file, server_port, console_port, nacos_version
update_port_config() {
    local config_file=$1
    local server_port=$2
    local console_port=$3
    local nacos_version=$4
    
    # Backup config file before modification
    backup_config_file "$config_file"
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    
    if [ "$nacos_major" -ge 3 ]; then
        # Nacos 3.x: separate main port and console port
        update_config_property "$config_file" "nacos.server.main.port" "$server_port"
        update_config_property "$config_file" "nacos.console.port" "$console_port"
    else
        # Nacos 2.x: only server.port
        update_config_property "$config_file" "server.port" "$server_port"
    fi
    
    rm -f "$config_file.bak"
}
