#!/bin/sh

#===============================================================================
# WordPress Production Deployment Script for Alpine Linux 3.22
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

# Install other required packages
echo "Installing required packages..." | tee -a "$LOG_FILE"
apk add --no-cache lighttpd curl \
    php84 php84-cli php84-fpm php84-opcache \
    php84-mysqli php84-json php84-phar \
    php84-session php84-curl php84-ctype \
    php84-mbstring php84-xml php84-zip iptables openssl || { echo "Error: Failed to install packages" | tee -a "$LOG_FILE"; exit 1; }

# Ensure MariaDB is in a clean state
if rc-service mariadb status >/dev/null 2>&1; then
    echo "Stopping MariaDB to ensure clean state..." | tee -a "$LOG_FILE"
    rc-service mariadb stop || { echo "Warning: Failed to stop MariaDB" | tee -a "$LOG_FILE"; }
fi

# Start MariaDB and verify
echo "Starting MariaDB..." | tee -a "$LOG_FILE"
rc-service mariadb start || { echo "Error: Failed to start MariaDB" | tee -a "$LOG_FILE"; exit 1; }
sleep 2
if ! rc-service mariadb status | grep -q "started"; then
    echo "Error: MariaDB is not running" | tee -a "$LOG_FILE"
    exit 1
fi

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
    echo "WP-CLI is already installed,28 skipping installation." | tee -a "$LOG_FILE"
else
    echo "Installing WP-CLI..." | tee -a "$LOG_FILE"
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || { echo "Error: Failed to download WP-CLI" | tee -a "$LOG_FILE"; exit 1; }
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# Create PHP symlink
if [ ! -f /usr/bin/php ] || [ ! -L /usr/bin/php ]; then
    echo "Creating PHP symlink..." | tee -a "$LOG_FILE"
    ln -sf /usr/bin/php84 /usr/bin/php
fi

# Configure PHP memory limit
PHP_INI_PATH="/etc/php84/php.ini"
if [ -f "$PHP_INI_PATH" ]; then
    if ! grep -q "memory_limit = 512M" "$PHP_INI_PATH"; then
        echo "Configuring PHP memory limit..." | tee -a "$LOG_FILE"
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI_PATH" || echo "Warning: Failed to update memory_limit" | tee -a "$LOG_FILE"
        if ! grep -q "memory_limit" "$PHP_INI_PATH"; then
            echo "memory_limit = 512M" >> "$PHP_INI_PATH"
        fi
    fi
else
    echo "Error: PHP ini file not found at $PHP_INI_PATH" | tee -a "$LOG_FILE"
    exit 1
fi

# Configure PHP-FPM
PHP_FPM_CONF="/etc/php84/php-fpm.d/www.conf"
if [ -f "$PHP_FPM_CONF" ]; then
    if ! grep -q "user = lighttpd" "$PHP_FPM_CONF"; then
        echo "Configuring PHP-FPM..." | tee -a "$LOG_FILE"
        sed -i 's/^user = .*/user = lighttpd/' "$PHP_FPM_CONF"
        sed -i 's/^group = .*/group = lighttpd/' "$PHP_FPM_CONF"
    fi
else
    echo "Error: PHP-FPM configuration file not found at $PHP_FPM_CONF" | tee -a "$LOG_FILE"
    exit 1
fi

# Create web directory and set permissions
echo "Setting up web directory..." | tee -a "$LOG_FILE"
mkdir -p "$WWW_DIR"
chown -R lighttpd:lighttpd "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# Install WordPress
if [ -f "$WWW_DIR/wp-settings.php" ]; then
    echo "WordPress is already installed in $WWW_DIR, skipping installation." | tee -a "$LOG_FILE"
else
    echo "Installing WordPress..." | tee -a "$LOG_FILE"
    cd "$WWW_DIR" || { echo "Error: Failed to change to $WWW_DIR" | tee -a "$LOG_FILE"; exit 1; }
    wp core download --allow-root || { echo "Error: Failed to download WordPress" | tee -a "$LOG_FILE"; exit 1; }
    wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=localhost --allow-root || { echo "Error: Failed to create wp-config.php" | tee -a "$LOG_FILE"; exit 1; }
    wp db create --allow-root || { echo "Error: Failed to create database schema" | tee -a "$LOG_FILE"; exit 1; }
    wp core install --url=https://"$SERVER_IP" --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL" --allow-root || { echo "Error: Failed to install WordPress" | tee -a "$LOG_FILE"; exit 1; }
fi

# Configure Lighttpd
if apk info | grep -q lighttpd; then
    if [ -f /etc/lighttpd/lighttpd.conf ] && [ -f /etc/lighttpd/mod_fastcgi_fpm.conf ] && grep -q "mod_fastcgi" /etc/lighttpd/lighttpd.conf && grep -q "fastcgi.server" /etc/lighttpd/mod_fastcgi_fpm.conf; then
        echo "Lighttpd is already configured, skipping configuration." | tee -a "$LOG_FILE"
    else
        echo "Configuring Lighttpd..." | tee -a "$LOG_FILE"
        cat > /etc/lighttpd/mod_fastcgi_fPM.conf <<EOF
server.modules += ( "mod_fastcgi" )

fastcgi.server = (
    ".php" => ((
        "socket" => "/run/php-fpm84/php-fpm.sock",
        "bin-path" => "/usr/bin/php-fpm84",
        "max-procs" => 2,
        "bin-environment" => (
            "PHP_FCGI_CHILDREN" => "4",
            "PHP_FCGI_MAX_REQUESTS" => "10000"
        )
    ))
)
EOF

        cat > /etc/lighttpd/lighttpd.conf <<EOF
var.basedir  = "/var/www/localhost"
var.logdir   = "/var/log/lighttpd"
var.statedir = "/var/lib/lighttpd"

server.modules = (
    "mod_access",
    "mod_accesslog",
    "mod_fastcgi",
    "mod_redirect"
)

server.username      = "-lighttpd"
server.groupname     = "lighttpd"
server.document-root = var.basedir + "/htdocs"
server.pid-file      = "/run/lighttpd.pid"
server.errorlog      = var.logdir  + "/error.log"

index-file.names     = ("index.php", "index.html", "index.htm", "default.htm")
static-file.exclude-extensions = (".php", ".pl", ".cgi", ".fcgi")
accesslog.filename   = var.logdir + "/access.log"
url.access-deny = ("~", ".inc")

include "mod_fastcgi_fpm.conf"
include "mod_ssl.conf"
EOF
    fi
else
    echo "Error: Lighttpd is not installed, but it is required." | tee -a "$LOG_FILE"
    exit 1
fi



# Configure iptables
if apk info | grep -q iptables; then
    if iptables -L INPUT -v -n | grep -qE "dpt:80|dpt:443"; then
        echo "Firewall already allows HTTP/HTTPS, skipping configuration." | tee -a "$LOG_FILE"
    else
        echo "Configuring iptables..." | tee -a "$LOG_FILE"
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        rc-service iptables save 2>/dev/null || echo "Warning: iptables rules not saved" | tee -a "$LOG_FILE"
    fi
else
    echo "iptables not installed, skipping firewall configuration." | tee -a "$LOG_FILE"
fi

# Restart services
echo "Restarting services..." | tee -a "$LOG_FILE"
rc-service mariadb restart || { echo "Error: Failed to restart MariaDB" | tee -a "$LOG_FILE"; exit 1; }
rc-service php-fpm84 restart || { echo "Error: Failed to restart PHP-FPM" | tee -a "$LOG_FILE"; exit 1; }
rc-service lighttpd restart || { echo "Error: Failed to restart Lighttpd" | tee -a "$LOG_FILE"; exit 1; }

# Enable services at boot
echo "Enabling services at boot..." | tee -a "$LOG_FILE"
rc-update add mariadb default
rc-update add php-fpm84 default
rc-update add lighttpd default

echo "WordPress setup complete. Access it at https://$SERVER_IP" | tee -a "$LOG_FILE"
