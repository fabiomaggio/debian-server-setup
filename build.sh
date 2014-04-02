#!/usr/bin/env bash

# ================================ #
# Define system specific variables #
# ================================ #

USER="fabio"
TIMEZONE="Europe/Brussels"
HOSTNAME="scheidingshuis"
SERVERIP="127.0.0.1"
DOMAIN="scheidingshuis.be"
SUBDOMAIN="www.scheidingshuis.be"

# Update the system
echo "> Updating the system..."
apt-get update &&
apt-get upgrade -y
echo

# Set hostname
echo "${HOSTNAME}" > /etc/hostname
hostname -F /etc/hostname
echo

# Update /etc/hosts
echo "> Updating /etc/hosts..."
mv /etc/hosts /etc/hosts.bak
echo "
127.0.0.1       localhost
127.0.0.1       ${HOSTNAME}
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
" >> /etc/hosts
echo

# Set the timezone

echo "> Setting the timezone to ${TIMEZONE}..."
cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo

# Change root password
echo "> Change root password"
passwd &&
echo

# =================== #
# Add user to sudoers #
# =================== #

# The user does not exist already
if [ ! id -u "${USER}" >/dev/null 2>&1 ]; then
    # Add the user
    echo "> Adding user ${USER} to sudoers..."
    adduser "${USER}" &&

    # Edit the sudoers file via the "visudo" command
    if [[ ! -z "$1" ]]; then
        echo "${USER}    ALL=(ALL) ALL" >> $1
    else
        export EDITOR=$0
        visudo
    fi
# The user does exist already
else
    echo "> Skipping creation of ${USER} because it already exists..."
fi

echo

# Create /srv directories

echo "> Creating /srv directories..."
mkdir -p /srv/backup &&
mkdir -p /srv/www
echo

# Disable root login
echo "> Disabling root SSH login..."
sed -i "s/PermitRootLogin yes/PermitRootLogin no/g" /etc/ssh/sshd_config
echo

# Restart SSH service
echo "> Restarting SSH service..."
service ssh restart
echo

# ================== #
# Configure firewall #
# ================== #

# Install iptables firewall
echo "> Installing iptables firewall..."
apt-get install -y iptables
echo

# Setup basic rules
echo "> Setting up basic firewall rules..."

# Flush old rules
iptables -F

# Allow SSH connections on tcp port 22
# This is essential when working on remote servers via SSH to prevent locking yourself out of the system
#
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Set default chain policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Accept packets belonging to established and related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow loopback access
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow incoming HTTP
iptables -A INPUT -i eth0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --sport 80 -m state --state ESTABLISHED -j ACCEPT

# Allow outgoing HTTPS
iptables -A OUTPUT -o eth0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --sport 80 -m state --state ESTABLISHED -j ACCEPT

# Allow incoming HTTPS
iptables -A INPUT -i eth0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

# Allow outgoing HTTPS
iptables -A OUTPUT -o eth0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

# Ping from inside to outside
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# Ping from outside to inside
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT

# Allow packets from internal network to reach external network.
# if eth1 is external, eth0 is internal
iptables -A FORWARD -i eth0 -o eth1 -j ACCEPT

# Allow Sendmail or Postfix
iptables -A INPUT -i eth0 -p tcp --dport 25 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --sport 25 -m state --state ESTABLISHED -j ACCEPT

# Help prevent DoS attack
iptables -A INPUT -p tcp --dport 80 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# Log dropped packets
iptables -N LOGGING
iptables -A INPUT -j LOGGING
iptables -I INPUT -m limit --limit 5/min -j LOG --log-prefix "Iptables Dropped Packet: " --log-level 7
iptables -A LOGGING -j DROP

echo

# Install iptables-persistent package
echo "> Installing iptables-persistent package..."
apt-get install -y iptables-persistent

# Save iptables rules
echo "> Saving iptables rules..."
/etc/init.d/iptables-persistent save

# Enable ip_conntrack_ftp module before iptables rules are loaded
sed --in-place "/rc=0/a  /sbin/modprobe -q i" /etc/init.d/iptables-persistent
echo

# Install fail2ban package
echo "> Installing fail2ban package..."
apt-get install -y fail2ban

# Backup fail2ban configuration file
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# Change fail2ban configuration file
sed --in-place "s@ignoreip = 127.0.0.1\/8@ignoreip = 127.0.0.1\/8 ${SERVERIP}@" /etc/fail2ban/jail.local
sed --in-place "s/bantime = 600/bantime = 3600/" /etc/fail2ban/jail.local

echo

# ====== #
# Apache #
# ====== #

# Install apache
echo "> Installing apache2 package..."
apt-get install -y apache2
echo

# Disable default site
echo "> Disabling default site..."
a2dissite default
echo

# Create website directory
echo "> Creating website directory structure in /srv/www/${DOMAIN}/${SUBDOMAIN}/..."
mkdir -p /srv/www/${DOMAIN}/${SUBDOMAIN}/{public,log,backup}
echo

# Set up virtual hosts
echo "> Creating VirtualHost for ${DOMAIN}..."
echo "<VirtualHost *:80>
  # Admin email, Server Name (domain name), and any aliases
  ServerAdmin postmaster@${DOMAIN}
  ServerName ${DOMAIN}
  ServerAlias ${SUBDOMAIN}

  # Index file and Document Root (where the public files are located)
  DirectoryIndex index.html index.php
  DocumentRoot /srv/www/${DOMAIN}/${SUBDOMAIN}/public

  <Directory />
    Options FollowSymLinks
    AllowOverride all
  </Directory>

  <Directory /srv/www/${DOMAIN}/${SUBDOMAIN}/public>
    Options Indexes FollowSymLinks MultiViews
    AllowOverride all
    Order allow,deny
    allow from all
  </Directory>

  # Log file locations
  LogLevel warn
  ErrorLog  /srv/www/${DOMAIN}/${SUBDOMAIN}/log/error.log
  CustomLog /srv/www/${DOMAIN}/${SUBDOMAIN}/log/access.log combined
</VirtualHost>
" > /etc/apache2/sites-available/${DOMAIN}

echo

# Enable site
echo "> Enabling site ${DOMAIN}, restarting apache..."
a2ensite ${DOMAIN}
echo

# Enable apache modules
echo "> Enabling apache modules..."
a2enmod rewrite
echo

# Disable directory listing
echo "> Disabling directory listing..."
a2dismod autoindex
echo

# ===== #
# MySQL #
# ===== #

# Install mysql server
echo "> Installing mysql server..."
apt-get install -y mysql-server && mysql_secure_installation
echo

# === #
# PHP #
# === #

# Install php
echo "> Installing php..."
apt-get install -y php5 php-pear php5-mysql
echo

# Restart apache
echo "> Restarting apache..."
/etc/init.d/apache2 restart
echo