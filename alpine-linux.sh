#!/bin/sh

#===============================================================================
# WordPress Production Deployment Script for Alpine Linux 3.22
#===============================================================================

# Configuration Variables
# Dynamically get the server's IP address
if command -v hostname >/dev/null 2>&1; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
elif command -v ip >/dev/null 2>&1; then
    SERVER_IP=$(ip addr show | grep -o "inet [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+" | grep -v "127.0.0.1" | head -n 1 | awk '{print $2}')
else
    echo "Error: Unable to determine IP address. Please set SERVER_IP manually."
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

# Update system packages
apk update && apk upgrade || { echo "Error: Failed to update packages"; exit 1; }

# Check if MariaDB is installed
if apk info | grep -q mariadb; then
    echo "MariaDB is already installed, skipping installation."
else
    # Install MariaDB and client
    apk add --no-cache mariadb mariadb-client || { echo "Error: Failed to install MariaDB"; exit 1; }
    # Initialize MariaDB
    if ! /etc/init.d/mariadb setup; then
        echo "Error: MariaDB setup failed"
        exit 1
    fi
fi

# Install other required packages (excluding MariaDB if already installed)
apk add --no-cache lighttpd curl \
    php84 php84-cli php84-fpm php84-opcache \
    php84-mysqli php84-json php84-phar \
    php84-session php84-curl php84-ctype \
    php84-mbstring php84-xml php84-zip iptables openssl || { echo "Error: Failed to install packages"; exit 1; }

# Start MariaDB and verify it's running
if ! rc-service mariadb status >/dev/null 2>&1; then
    rc-service mariadb start || { echo "Error: Failed to start MariaDB"; exit 1; }
    sleep 2 # Give MariaDB time to start
fi
if ! rc-service mariadb status | grep -q "started"; then
    echo "Error: MariaDB is not running"
    exit 1
fi

# Create database and user (skip if database exists)
if mariadb -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='$DB_NAME';" | grep -q 1; then
    echo "Database $DB_NAME already exists, skipping creation."
else
    mariadb -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" || { echo "Error: Failed to create database"; exit 1; }
    mariadb -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" || { echo "Error: Failed to create database user"; exit 1; }
    mariadb -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || { echo "Error: Failed to grant privileges"; exit 1; }
    mariadb -e "FLUSH PRIVILEGES;" || { echo "Error: Failed to flush privileges"; exit 1; }
fi

# Install WP-CLI if not already installed
if ! command -v wp >/dev/null 2>&1; then
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || { echo "Error: Failed to download WP-CLI"; exit 1; }
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
else
    echo "WP-CLI is already installed, skipping installation."
fi

# Create PHP symlink if not exists
if [ ! -f /usr/bin/php ] || [ ! -L /usr/bin/php ]; then
    ln -sf /usr/bin/php84 /usr/bin/php
fi

# Configure PHP memory limit
PHP_INI_PATH="/etc/php84/php.ini"
if [ -f "$PHP_INI_PATH" ]; then
    if ! grep -q "memory_limit = 512M" "$PHP_INI_PATH"; then
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI_PATH" || echo "Warning: Failed to update memory_limit"
        if ! grep -q "memory_limit" "$PHP_INI_PATH"; then
            echo "memory_limit = 512M" >> "$PHP_INI_PATH"
        fi
    fi
else
    echo "Error: PHP ini file not found at $PHP_INI_PATH"
    exit 1
fi

# Configure PHP-FPM
PHP_FPM_CONF="/etc/php84/php-fpm.d/www.conf"
if [ -f "$PHP_FPM_CONF" ]; then
    if ! grep -q "user = lighttpd" "$PHP_FPM_CONF"; then
        sed -i 's/^user = .*/user = lighttpd/' "$PHP_FPM_CONF"
        sed -i 's/^group = .*/group = lighttpd/' "$PHP_FPM_CONF"
    fi
else
    echo "Error: PHP-FPM configuration file not found at $PHP_FPM_CONF"
    exit 1
fi

# Create web directory and set permissions
mkdir -p "$WWW_DIR"
chown -R lighttpd:lighttpd "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# Check if WordPress is installed
if [ -f "$WWW_DIR/wp-settings.php" ]; then
    echo "WordPress is already installed in $WWW_DIR, skipping installation."
else
    # Install WordPress
    cd "$WWW_DIR" || { echo "Error: Failed to change to $WWW_DIR"; exit 1; }
    wp core download --allow-root || { echo "Error: Failed to download WordPress"; exit 1; }
    wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=localhost --allow-root || { echo "Error: Failed to create wp-config.php"; exit 1; }
    wp db create --allow-root || { echo "Error: Failed to create database schema"; exit 1; }
    wp core install --url=http://"$SERVER_IP" --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL" --allow-root || { echo "Error: Failed to install WordPress"; exit 1; }
fi

# Check if Lighttpd is installed and configured
if apk info | grep -q lighttpd; then
    # Check if Lighttpd is properly configured
    if [ -f /etc/lighttpd/lighttpd.conf ] && [ -f /etc/lighttpd/mod_fastcgi_fpm.conf ] && grep -q "mod_fastcgi" /etc/lighttpd/lighttpd.conf && grep -q "fastcgi.server" /etc/lighttpd/mod_fastcgi_fpm.conf; then
        echo "Lighttpd is already configured, skipping configuration."
    else
        # Configure Lighttpd for PHP support
        cat > /etc/lighttpd/mod_fastcgi_fpm.conf <<EOF
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
    "mod_fastcgi"
)

server.username      = "lighttpd"
server.groupname     = "lighttpd"
server.document-root = var.basedir + "/htdocs"
server.pid-file      = "/run/lighttpd.pid"
server.errorlog      = var.logdir  + "/error.log"

index-file.names     = ("index.php", "index.html", "index.htm", "default.htm")
static-file.exclude-extensions = (".php", ".pl", ".cgi", ".fcgi")
accesslog.filename   = var.logdir + "/access.log"
url.access-deny = ("~", ".inc")

include "mod_fastcgi_fpm.conf"
EOF
    fi
else
    echo "Error: Lighttpd is not installed, but it is required."
    exit 1
fi

# Configure self-signed SSL certificate for Lighttpd
if [ -f "/etc/ssl/certs/$(hostname -d).pem" ]; then
    echo "SSL certificate already exists, skipping creation."
else
    mkdir -p /etc/ssl/certs/
    openssl req -x509 -days 1460 -nodes -newkey rsa:4096 \
        -subj "/C=VE/ST=Bolivar/L=Upata/O=VenenuX/OU=Systemas:hozYmartillo/CN=$(hostname -d)" \
        -keyout /etc/ssl/certs/$(hostname -d).pem -out /etc/ssl/certs/$(hostname -d).pem || { echo "Error: Failed to generate SSL certificate"; exit 1; }
    chmod 640 /etc/ssl/certs/$(hostname -d).pem
fi

# Configure Lighttpd SSL
if [ -f /etc/lighttpd/mod_ssl.conf ] && grep -q "ssl.engine" /etc/lighttpd/mod_ssl.conf; then
    echo "Lighttpd SSL configuration already exists, skipping configuration."
else
    cat > /etc/lighttpd/mod_ssl.conf <<EOF
server.modules += ("mod_openssl")
\$SERVER["socket"] == "0.0.0.0:443" {
    ssl.engine  = "enable"
    ssl.pemfile = "/etc/ssl/certs/$(hostname -d).pem"
}
\$HTTP["scheme"] == "http" {
    url.redirect = ("" => "https://\${url.authority}\${url.path}\${qsa}")
    url.redirect-code = 308
}
EOF
fi

# Update Lighttpd configuration to include mod_ssl.conf
if ! grep -q 'include "mod_ssl.conf"' /etc/lighttpd/lighttpd.conf; then
    sed -i -r 's#.*include "mod_fastcgi_fpm.conf".*#include "mod_fastcgi_fpm.conf"\ninclude "mod_ssl.conf"#g' /etc/lighttpd/lighttpd.conf || { echo "Error: Failed to update lighttpd.conf"; exit 1; }
fi

# Ensure mod_redirect is enabled in lighttpd.conf
if ! grep -q "mod_redirect" /etc/lighttpd/lighttpd.conf; then
    sed -i -r 's#.*"mod_fastcgi".*#    "mod_fastcgi",\n    "mod_redirect"#g' /etc/lighttpd/lighttpd.conf || { echo "Error: Failed to enable mod_redirect"; exit 1; }
fi

# Check if iptables is installed and configured
if apk info | grep -q iptables; then
    # Check if HTTP and HTTPS ports are already allowed
    if iptables -L INPUT -v -n | grep -qE "dpt:80|dpt:443"; then
        echo "Firewall already allows HTTP/HTTPS, skipping configuration."
    else
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        rc-service iptables save 2>/dev/null || echo "Warning: iptables rules not saved"
    fi
else
    echo "iptables not installed, skipping firewall configuration."
fi

# Restart services
rc-service mariadb restart || { echo "Error: Failed to restart MariaDB"; exit 1; }
rc-service php-fpm84 restart || { echo "Error: Failed to restart PHP-FPM"; exit 1; }
rc-service lighttpd restart || { echo "Error: Failed to restart Lighttpd"; exit 1; }

# Enable services at boot
rc-update add mariadb default
rc-update add php-fpm84 default
rc-update add lighttpd default

echo "WordPress setup complete. Access it at https://$SERVER_IP"
