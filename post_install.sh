set -e

# Check for min system requirements
if (($(($(free -mt|awk '/^Total:/{print $2}')*1)) <= 700)); then
   echo -e "EasyMail has been stopped because of the following minimum requirements:\n";
   echo -e "- RAM (or RAM + SWAP) >= 1GB\n\n";
   exit;
fi

# run only once
ALREADY_RUN_POST_INSTALL_FILE="/opt/easymail/already-run-post-install.txt"

if [ ! -e "$ALREADY_RUN_POST_INSTALL_FILE" ]; then
  mkdir /etc/opendkim/keys -p
  echo "127.0.0.1
localhost
192.168.0.1/24
" >> /etc/opendkim/TrustedHosts
  chown opendkim:opendkim /etc/opendkim/ -R
  chown -R mysql:mysql /var/lib/mysql /var/run/mysqld
fi

bash /run.sh;

if [ -e "$ALREADY_RUN_POST_INSTALL_FILE" ]; then
  exit;
fi

touch $ALREADY_RUN_POST_INSTALL_FILE

# create payload directory
mkdir -p /opt/easymail/data/{mysql,dovecot,ssl}

# Get variables
export EASYMAIL_CONFIG="/opt/easymail/config.ini"
export ROUNDCUBE_MYSQL_USERNAME=$(cat "$EASYMAIL_CONFIG" | grep mysql_roundcube_username: | awk -F':' '{ print $2;}')

export MYSQL_HOSTNAME=$(cat "$EASYMAIL_CONFIG" | grep mysql_easymail_hostname: | awk -F':' '{ print $2;}')
export MYSQL_USERNAME=$(cat "$EASYMAIL_CONFIG" | grep mysql_easymail_username: | awk -F':' '{ print $2;}')

export ROOT_MYSQL_USERNAME=$(cat "$EASYMAIL_CONFIG" | grep mysql_root_username: | awk -F':' '{ print $2;}')
export OLD_ROOT_MYSQL_PASSWORD=$(cat "$EASYMAIL_CONFIG" | grep mysql_root_password: | awk -F':' '{ print $2;}')
export MYSQL_DATABASE=$(cat "$EASYMAIL_CONFIG" | grep mysql_easymail_database: | awk -F':' '{ print $2;}')

# Define some functions
function set_hostname {
	sed -i "s/__EASYMAIL_HOSTNAME__/$HOSTNAME/g" $1
}

function get_rand_password() {
	< /dev/urandom tr -dc A-Za-z-0-9 | head -c${1:-60};
}

function apply_easymail_configs {
	export FILEPATH=$1;

	sed -i "s/__EASYMAIL_MYSQL_PASSWORD__/$MYSQL_PASSWORD/g" $FILEPATH
	sed -i "s/__EASYMAIL_ROOT_MYSQL_PASSWORD__/$ROOT_MYSQL_PASSWORD/g" $FILEPATH
	sed -i "s/__EASYMAIL_ROUNDCUBE_MYSQL_PASSWORD__/$ROUNDCUBE_MYSQL_PASSWORD/g" $FILEPATH

	sed -i "s/__EASYMAIL_ADMIN_PASSWORD_UNENCRYPTED__/$ADMIN_PASSWORD_UNENCRYPTED/g" $FILEPATH

	sed -i "s/__EASYMAIL_HOSTNAME__/$HOSTNAME/g" $FILEPATH

	sed -i "s/__EASYMAIL_MANAGEMENT_API_USERNAME__/$MANAGEMENT_API_USERNAME/g" $FILEPATH
	sed -i "s/__EASYMAIL_MANAGEMENT_API_PASSWORD__/$MANAGEMENT_API_PASSWORD/g" $FILEPATH
	sed -i "s/__EASYMAIL_MANAGEMENT_API_SECRETKEY__/$MANAGEMENT_API_SECRETKEY/g" $FILEPATH
}

export -f set_hostname

# Re-generate the passwords
export ADMIN_PASSWORD_UNENCRYPTED=$(get_rand_password)
export ADMIN_PASSWORD=$(openssl passwd -1 $ADMIN_PASSWORD_UNENCRYPTED)
export ROOT_MYSQL_PASSWORD=$(get_rand_password)
export MYSQL_PASSWORD=$(get_rand_password)
export ROUNDCUBE_MYSQL_PASSWORD=$(get_rand_password)

export MANAGEMENT_API_USERNAME="easyadmin"
export MANAGEMENT_API_PASSWORD=${1:-$(get_rand_password)}
export MANAGEMENT_API_SECRETKEY=$(get_rand_password)

export SSL_CA_BUNDLE_FILE="/opt/easymail/data/ssl/public.pem"
export SSL_PRIVATE_KEY_FILE="/opt/easymail/data/ssl/private.pem"

chmod 0777 -R /opt/easymail/data/ssl

# if the sertificate files are there don't re-generate them.
if [ ! -e "$SSL_CA_BUNDLE_FILE" ] || [ ! -e "$SSL_PRIVATE_KEY_FILE" ]  ; then
  # Re-generate the self-signed certificate
  openssl req -new -x509 -days 365000 -nodes -subj "/C=/ST=/L=/O=/CN=EasyMail" -out "$SSL_CA_BUNDLE_FILE" -keyout "$SSL_PRIVATE_KEY_FILE"
fi

# new SSL location for Postfix
postconf -e smtpd_tls_cert_file=$SSL_CA_BUNDLE_FILE
postconf -e smtpd_tls_key_file=$SSL_PRIVATE_KEY_FILE

# new SSL location for Nginx
# sed -i -e "s#ssl_certificate .*#ssl_certificate $SSL_CA_BUNDLE_FILE;#g" /etc/nginx/sites-enabled/roundcube
# sed -i -e "s#ssl_certificate_key .*#ssl_certificate_key $SSL_PRIVATE_KEY_FILE;#g" /etc/nginx/sites-enabled/roundcube

# new SSL location for Dovecot
sed -i -e "s#ssl_cert .*#ssl_cert = <$SSL_CA_BUNDLE_FILE#g" /etc/dovecot/dovecot.conf
sed -i -e "s#ssl_key .*#ssl_key = <$SSL_PRIVATE_KEY_FILE#g" /etc/dovecot/dovecot.conf

# Set HOSTNAME for auto configurations
set_hostname /usr/share/nginx/autoconfig_and_autodiscover/autoconfig.php
set_hostname /usr/share/nginx/autoconfig_and_autodiscover/autodiscover.php

# Set HOSTNAME for Roundcube
set_hostname /etc/nginx/sites-enabled/roundcube

# Set HOSTNAME for Postfix
debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"

# Set HOSTNAME for MySQL
export ADMIN_EMAIL="admin@$HOSTNAME"
mysql -h $MYSQL_HOSTNAME -u$ROOT_MYSQL_USERNAME -p$OLD_ROOT_MYSQL_PASSWORD << EOF

USE $MYSQL_DATABASE;

UPDATE \`virtual_domains\`
SET \`name\`='$HOSTNAME'
WHERE \`id\`='1';

UPDATE \`virtual_users\`
SET \`email\`='$ADMIN_EMAIL', \`password\`='$ADMIN_PASSWORD'
WHERE \`id\`='1';

ALTER USER 'roundcube_user'@'127.0.0.1' IDENTIFIED BY '$ROUNDCUBE_MYSQL_PASSWORD';
ALTER USER 'mailuser'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_MYSQL_PASSWORD';
EOF

# reset generate roundcubemail
apply_easymail_configs /usr/share/nginx/roundcubemail/plugins/password/config.inc.php
apply_easymail_configs /usr/share/nginx/roundcubemail/config/config.inc.php
apply_easymail_configs /usr/share/nginx/roundcubemail/public_html/plugins/password/config.inc.php

# Set HOSTNAME for Dovecot
mkdir -p /var/mail/vhosts/$HOSTNAME
chown vmail:vmail /var/mail/vhosts -R

apply_easymail_configs /etc/dovecot/dovecot.conf
apply_easymail_configs /etc/dovecot/dovecot-sql.conf.ext
apply_easymail_configs /etc/dovecot/conf.d/20-lmtp.conf
echo "log_path = /opt/easymail/logs/dovecot.log" >> /etc/dovecot/dovecot.conf

postconf -e myhostname="$HOSTNAME"
apply_easymail_configs /etc/postfix/mysql-virtual-mailbox-maps.cf
apply_easymail_configs /etc/postfix/mysql-recipient-bcc-maps.cf
apply_easymail_configs /etc/postfix/mysql-virtual-alias-maps.cf
apply_easymail_configs /etc/postfix/mysql-virtual-mailbox-domains.cf
apply_easymail_configs /etc/opendkim.conf

# Reload services
service nginx restart
service dovecot reload
service postfix reload

# Set HOSTNAME Management API
apply_easymail_configs /opt/easymail/ManagementAPI/config.ini

echo "Create a log dir"
mkdir /opt/easymail/logs/

echo "Kill ManagementAPI"
pkill ManagementAPI && cd /opt/easymail/ManagementAPI

echo "Run ManagementAPI"
./ManagementAPI > /opt/easymail/logs/ManagementAPI.log 2>&1 &

echo "Add new configurations to easymail config file"
apply_easymail_configs $EASYMAIL_CONFIG

# update-ca-certificates
