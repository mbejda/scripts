#!/bin/sh

# Install required packages
apk add openssl

# Set domain and paths
DOMAIN="codeexecutives.com"
HTTPD_CONF="/etc/lighttpd/lighttpd.conf"
SSL_DIR="/etc/lighttpd/ssl"
CERT_FILE="$SSL_DIR/$DOMAIN.crt"
KEY_FILE="$SSL_DIR/$DOMAIN.key"

# Create SSL directory
mkdir -p "$SSL_DIR"

# Generate self-signed certificate
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CERT_FILE" -days 365 -nodes \
    -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$DOMAIN"

# Set permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Backup existing configuration
cp "$HTTPD_CONF" "$HTTPD_CONF.bak"

# Add SSL and virtual host configuration
cat >> "$HTTPD_CONF" << EOF

# SSL Configuration for $DOMAIN
server.modules += ( "mod_openssl" )

\$SERVER["socket"] == ":443" {
    ssl.engine = "enable"
    ssl.pemfile = "$CERT_FILE"
    ssl.privkey = "$KEY_FILE"
}

# Virtual Host Configuration
\$HTTP["host"] =~ "^(www\.)?$DOMAIN$" {
    server.document-root = "/var/www/$DOMAIN"
    server.errorlog = "/var/log/lighttpd/$DOMAIN-error.log"
    accesslog.filename = "/var/log/lighttpd/$DOMAIN-access.log"
}

EOF

# Create document root directory
mkdir -p "/var/www/$DOMAIN"

# Create log directory
mkdir -p "/var/log/lighttpd"

# Test configuration
lighttpd -t -f "$HTTPD_CONF"

# Restart lighttpd
rc-service lighttpd restart

echo "Domain $DOMAIN with self-signed SSL has been configured."
echo "Document root: /var/www/$DOMAIN"
echo "Certificate: $CERT_FILE"
echo "Private key: $KEY_FILE"
