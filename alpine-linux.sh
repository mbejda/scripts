#!/bin/sh

#===============================================================================
# WordPress Production Deployment Script for Alpine Linux 3.22 (HTTP Only)
# Fixed for 403 Forbidden Error and iptables Typo
#===============================================================================

# Configuration Variables
LOG_FILE="/var/log/wordpress_setup.log"
SERVER_IP=$(ip addr show | grep -o "inet [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+" | grep -v "127.0.0.1" | head -n 1 | awk '{print $2}' || hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    echo "Error: Unable to determine IP address. Please set SERVER_IP manually." | tee -a "$LOG_FILE"
    exit 1
fi
DB_NAME="wordpress"
DB_USER="wordpress"
DB_PASS="wordpress"
WP_ADMIN_USER="admin"
WP_ADMIN_PASS="admin"
WP_ADMIN_EMAIL="admin@admin.com"
WP_SITE_TITLE="WordPress Site"
WWW_DIR="/var/www/localhost/htdocs"

# Create log file
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Update system packages
echo "Updating system packages..." | tee -a "$LOG_FILE"
apk update && apk upgrade || { echo "Error: Failed to update packages" | tee -a "$LOG_FILE"; exit 1; }

# Check if MariaDB is installed
if apk info | grep -q mariadb; then
    echo "MariaDB is already installed, skipping installation." | tee -a "$LOG_FILE"
else
    echo "Installing MariaDB..." | tee -a "$LOG_FILE"
    apk add --no-cache mariadb mariadb-client || { echo "Error: Failed to install MariaDB" | tee -a "$LOG_FILE"; exit 1; }
    # Initialize MariaDB only if data directory doesn't exist
    if [ ! -d "/var/lib/mysql/mysql" ]; then
        if ! /etc/init.d/mariadb setup; then
            echo "Error: MariaDB setup failed" | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
fi

# Check MariaDB status and handle crash
echo "Checking MariaDB status..." | tee -a "$LOG_FILE"
if rc-service mariadb status >/dev/null 2>&1; then
    if rc-service mariadb status | grep -q "crashed"; then
        echo "MariaDB is in crashed state, attempting to restart..." | tee -a "$LOG_FILE"
        rc-service mariadb stop || { echo "Warning: Failed to stop crashed MariaDB" | tee -a "$LOG_FILE"; }
        sleep 2
        rc-service mariadb start || { echo "Error: Failed to restart MariaDB" | tee -a "$LOG_FILE"; exit 1; }
        sleep 2
        if ! rc-service mariadb status | grep -q "started"; then
            echo "Error: MariaDB failed to start after restart attempt" | tee -a "$LOG_FILE"
            exit 1
        else
            echo "MariaDB successfully restarted." | tee -a "$LOG_FILE"
        fi
    else
        echo "MariaDB is running, no restart needed." | tee -a "$LOG_FILE"
    fi
else
    echo "MariaDB is not running, starting it..." | tee -a "$LOG_FILE"
    rc-service mariadb start || { echo "Error: Failed to start MariaDB" | tee -a "$LOG_FILE"; exit 1; }
    sleep 2
    if ! rc-service mariadb status | grep -q "started"; then
        echo "Error: MariaDB is not running after start attempt" | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# Install other required packages
echo "Installing required packages..." | tee -a "$LOG_FILE"
apk add --no-cache lighttpd curl \
    php84 php84-cli php84-fpm php84-opcache \
    php84-mysqli php84-json php84-phar \
    php84-session php84-curl php84-ctype \
    php84-mbstring php84-xml php84-zip iptables || { echo "Error: Failed to install packages" | tee -a "$LOG_FILE"; exit 1; }

# Create database and user
if mariadb -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='$DB_NAME';" | grep -q 1; then
    echo "Database $DB_NAME already exists, skipping creation." | tee -a "$LOG_FILE"
else
    echo "Creating database and user..." | tee -a "$LOG_FILE"
    mariadb -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" || { echo "Error: Failed to create database" | tee -a "$LOG_FILE"; exit 1; }
    mariadb -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" || { echo "Error: Failed to create database user" | tee -a "$LOG_FILE"; exit 1; }
    mariadb -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || { echo "Error: Failed to grant privileges" | tee -a "$LOG_FILE"; exit 1; }
    mariadb -e "FLUSH PRIVILEGES;" || { echo "Error: Failed to flush privileges" | tee -a "$LOG_FILE"; exit 1; }
fi

# Install WP-CLI
if command -v wp >/dev/null 2>&1; then
    echo "WP-CLI is already installed, skipping installation." | tee -a "$LOG_FILE"
else
    echo "Installing WP-CLI..." | tee -a "$LOG_FILE"
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || { echo "Error: Failed to download WP-CLI" | tee -a "$LOG_FILE"; exit 1; }
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# Create PHP symlink
if [ ! -f /usr/bin/php ] || [ ! -L /usr/bin/php ]; then
    echo "Creatingつまり
System: * Today's date and time is 09:30 AM EDT on Monday, July 21, 2025.
