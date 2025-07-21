#!/bin/sh

#===============================================================================
# WordPress Production Deployment Script for Alpine Linux
#===============================================================================

# Configuration Variables
SERVER_IP="45.76.248.88"
DB_NAME="wordpress"
DB_USER="wordpress"
DB_PASS="wordpress"
WP_ADMIN_USER="admin"
WP_ADMIN_PASS="admin"
WP_ADMIN_EMAIL="admin@admin.com"
WP_SITE_TITLE="WordPress Site"

# Update system packages
apk update && apk upgrade

# Install required packages
apk add --no-cache mariadb mariadb-client lighttpd curl \
    php84 php84-cli php84-fpm php84-opcache \
    php84-mysqli php84-json php84-phar \
    php84-session php84-curl php84-ctype \
    php84-mbstring php84-xml php84-zip

# Initialize MariaDB
/etc/init.d/mariadb setup

# Create database user with privileges
rc-service mariadb start
mariadb -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mariadb -e "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;"
mariadb -e "FLUSH PRIVILEGES;"

# Install WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# Create PHP symlink
ln -s /usr/bin/php84 /usr/bin/php

# Configure PHP memory limit
PHP_INI_PATH="/etc/php84/php.ini"
if [ -f "$PHP_INI_PATH" ]; then
    sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI_PATH"
    if ! grep -q "memory_limit" "$PHP_INI_PATH"; then
        echo "memory_limit = 512M" >> "$PHP_INI_PATH"
    fi
else
    echo "PHP ini file not found at $PHP_INI_PATH"
fi


# Configure Lighttpd for PHP support
cat > /etc/lighttpd/lighttpd.conf <<EOF
var.basedir  = "/var/www/localhost"
var.logdir   = "/var/log/lighttpd"
var.statedir = "/var/lib/lighttpd"

server.modules = (
    "mod_access",
    "mod_accesslog"
)

include "mod_fastcgi_fpm.conf"

server.username      = "lighttpd"
server.groupname     = "lighttpd"
server.document-root = var.basedir + "/htdocs"
server.pid-file      = "/run/lighttpd.pid"
server.errorlog      = var.logdir  + "/error.log"

index-file.names     = ("index.php", "index.html", "index.htm", "default.htm")
static-file.exclude-extensions = (".php", ".pl", ".cgi", ".fcgi")
accesslog.filename   = var.logdir + "/access.log"
url.access-deny = ("~", ".inc")
EOF

# make delay 5 seconds
sleep 5

# Install WordPress
if [ ! -d /var/www/localhost/htdocs ]; then
    mkdir -p /var/www/localhost/htdocs
fi
cd /var/www/localhost/htdocs
wp core download --allow-root
wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=localhost --allow-root
wp db create --allow-root
wp core install --url=http://"$SERVER_IP" --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL" --allow-root


# Configure firewall
if command -v ufw >/dev/null 2>&1; then
    ufw --force enable
    ufw allow 80/tcp
    ufw allow 443/tcp
else
    echo "UFW not installed, no firewall configuration needed"
fi

# Restart services
rc-service mariadb restart
rc-service php-fpm84 restart
rc-service lighttpd restart

# Enable services at boot
rc-update add mariadb default
rc-update add php-fpm84 default
rc-update add lighttpd default
