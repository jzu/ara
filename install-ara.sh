#!/bin/bash

# install-ara.sh
# Avalanche Remote Access - Reverse Proxy Installer
# (C) 2021 Jean Zundel <jzu@free.fr> - MIT License
# See https://github.com/jzu/ara

export LANG=C
export LC_ALL=C

CGIDIR=/var/www/avacgi
CGI=$CGIDIR/index.cgi


# CHECKS

if [ -n "$1" ] && [ "$1" != "--uninstall" ]
then
  cat <<EOT
Usage: $0 [--uninstall]"

Clients will access the JSON API through port 19560 using a P12 keypair.

Installs an Apache CGI/SSL reverse proxy to the Avalanche JSON API,
generates X.509v3 certificates for secure remote communication,
creates a virtual host configuration file and a CGI wrapper.

--uninstall removes the virtual host from the Apache configuration.
EOT
  exit 1
fi

# Superuser?

if [ `whoami` != "root" ]
then
  echo ERROR: You need superpowers to run this installer. Please use sudo.
  exit 1
fi

# Undo?

if [ "$1" = "--uninstall" ]
then
  echo
  read -p "This will remove the Avalanche CGI Proxy. Are you sure [Y]? " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || \
    exit 1
  echo
  cd /etc/apache2
  sed -i '/19650/d' ports.conf
  /bin/rm -f sites-available/ara.conf sites-enabled/ara.conf
  echo "Uninstalled! To restart Apache:"
  echo "sudo service apache2 restart"
  exit 0
fi

# avalanchego running?

pgrep avalanchego &>/dev/null || \
  echo WARNING: avalanchego is not currently running.

# Apache installed?

if [ ! -f /etc/apache2/apache2.conf ]
then
  echo ERROR: Apache is not installed.
  You can run "apt install apache2" to install it.
  exit 1
fi

# ...already running?

[ -f /var/run/apache2/apache2.pid ] ||
  echo WARNING: Apache is not currently running.

# ...what about port 19650?

if netstat -tan \
   | sed 's/tcp  * 0  * 0  *\([^ ]*\).*/\1/' \
   | grep -q ":19560"
then
  echo ERROR: port 19560 is already bound.
  exit 1
fi

# VHost for 19650 already created?

if [ -f /etc/apache2/sites-available/ara.conf ]
then
  echo ERROR: /etc/apache2/sites-available/ara.conf already present.
  exit 1
fi

# Last chance

echo
echo "This script will install the Avalanche CGI Proxy by:"
echo "- Creating server and client certificates"
echo "- Activating port 19560 on Apache on which a CGI will be running"
read -p "Are you sure [Y]? " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || \
  exit 1
echo


# PKI

# Prep

mkdir -p /etc/apache2/ssl
cd /etc/apache2/ssl
dd if=/dev/urandom bs=256 count=1 of=~/.rnd
dd if=/dev/urandom bs=20 count=1 2>/dev/null \
| xxd -p \
| tr "[a-z]" "[A-Z]" > ca.srl
echo 01 > index.txt
cat <<EOT > ca.cnf
[ca]
default_ca=avalanche

[avalanche]
database=./index.txt

[cert]
authorityKeyIdentifier=keyid,issuer
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
EOT

# CA

openssl genrsa -out ca.key 4096        # Hello Claus
openssl req -x509 \
            -new \
            -nodes \
            -key ca.key \
            -sha256 \
            -days 3650 \
            -out ca.crt \
            -subj "/O=Avalanche/CN=CA"

# Server key and cert

openssl req -new \
            -newkey rsa:2048 \
            -keyout avalanche.key \
            -nodes \
            -out avalanche.csr \
            -subj "/O=Avalanche/CN=`hostname -f`"
openssl x509 -req \
             -in avalanche.csr \
             -CA ca.crt \
             -CAkey ca.key \
             -out avalanche.crt \
             -days 730 \
             -sha256 \
             -extfile ca.cnf \
             -extensions cert

# Client P12

openssl req -new \
            -newkey rsa:2048 \
            -keyout api.key \
            -out api.csr \
            -nodes \
            -subj "/O=Avalanche/CN=API"
openssl x509 -req \
             -days 1461 \
             -in api.csr \
             -CA ca.crt \
             -CAkey ca.key \
             -out api.crt
openssl pkcs12 -export \
               -inkey api.key \
               -in api.crt \
               -CAfile ca.crt \
               -out /tmp/api.p12 \
               -passout pass:
chmod 644 /tmp/api.p12
/bin/rm api.key api.csr api.crt


# APACHE

# ports.conf

grep -q 19650 /etc/apache2/ports.conf || \
  echo -e 'Listen 19650' >> /etc/apache2/ports.conf

# VHost

cat <<EOT > /etc/apache2/sites-available/ara.conf
<VirtualHost *:19650>

  ServerName `hostname -f`

  DocumentRoot $CGIDIR 

  SSLEngine on
  SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
  SSLCipherSuite HIGH:!aECDH:!aNULL:!eNULL:+SHA1:!MD5:!RC4:!CAMELLIA:!SEED:!DH:!3DES:!PSK:!IDEA:!SRP:!KRB5
  SSLHonorCipherOrder on
  SSLOptions +StdEnvVars +ExportCertData +StrictRequire
  SSLCertificateKeyFile /etc/apache2/ssl/avalanche.key
  SSLCertificateFile /etc/apache2/ssl/avalanche.crt
  SSLCACertificateFile /etc/apache2/ssl/ca.crt
  SSLVerifyClient require

  RewriteEngine On
  RewriteRule "^/?(.*)" "/index.cgi?/\$1" [PT]

  AddType application/x-httpd-cgi .cgi

  <Directory $CGIDIR>
    SSLRequire ( %{SSL_CLIENT_VERIFY} eq "SUCCESS" )
    Options +ExecCGI
  </Directory>

</VirtualHost>
EOT

cd /etc/apache2/sites-enabled
ln -sf ../sites-available/ara.conf .

# CGI

mkdir -p $CGIDIR
cat <<EOT > $CGI
#!/bin/bash

read IN
echo -ne "Content-type: application/json;\r\n\r\n"
curl -s -X POST --data "\$IN" -H 'Content-type: application/json;' localhost:9650\$QUERY_STRING
EOT
chown www-data: $CGI
chmod 755 $CGI

cat <<EOT
Avalanche CGI Proxy installed.

Changes will be effective when you restart Apache:
sudo service apache2 restart

Your client certificate is in /tmp/api.p12 (no password).
You should delete it after having downloaded it.
EOT
