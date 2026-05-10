#!/bin/bash
set -e

cd "$(dirname "$0")"
source ./config

mkdir -p certs etc "$NGINX_LOG_DIR"
hostname "$HOST_NAME"
echo "$EXTERNAL_IP $HOST_NAME" >> /etc/hosts

################### INSTALL DOCKER ###########################
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce

# Install docker-compose from official GitHub release (apt version on Xenial is too old for v2 format)
COMPOSE_VERSION="1.21.2"
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

################# CERT CREATE CONFIG ##########################
cat > /tmp/openssl-san.cnf << EOF
[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[ req_distinguished_name ]
C  = UA
L  = Kharkiv
O  = DLNet
OU = NOC
CN = ${HOST_NAME}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName   = @alt_names

[alt_names]
IP.1  = ${EXTERNAL_IP}
DNS.1 = ${HOST_NAME}
EOF

################# CERT GENERATE ###############################
openssl genrsa -out certs/root.key 4096
openssl req -x509 -new -key certs/root.key -days 365 -out certs/root.crt \
    -subj "/C=UA/L=Kharkiv/O=DLNet/OU=NOC/CN=dlnet.kharkov.com"
openssl genrsa -out certs/web.key 4096
openssl req -new -key certs/web.key -out certs/web.csr -config /tmp/openssl-san.cnf
openssl x509 -req -in certs/web.csr -CA certs/root.crt -CAkey certs/root.key \
    -CAcreateserial -out certs/web.crt -days 365 \
    -extensions v3_req -extfile /tmp/openssl-san.cnf
cat certs/root.crt >> certs/web.crt

################# NGINX CONFIG ################################
cat > etc/nginx.conf << EOF
server {
    listen ${NGINX_PORT} ssl;
    ssl_certificate     /etc/ssl/certs/nginx/web.crt;
    ssl_certificate_key /etc/ssl/certs/nginx/web.key;

    location / {
        proxy_pass         http://apache;
        proxy_redirect     off;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Host \$server_name;
    }
}
EOF

################# DOCKER COMPOSE CONFIG #######################
cat > docker-compose.yml << EOF
version: '2'
services:
  nginx:
    image: ${NGINX_IMAGE}
    ports:
      - '${NGINX_PORT}:${NGINX_PORT}'
    volumes:
      - ./etc/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${NGINX_LOG_DIR}:/var/log/nginx
      - ./certs:/etc/ssl/certs/nginx
    depends_on:
      - apache
  apache:
    image: ${APACHE_IMAGE}
EOF

docker-compose up -d
docker-compose ps
