#! /usr/bin/env sh
# This script sets up Fate on a server.

# Usage: sudo ./setup.sh (after running chmod +x setup.sh)

set -e

log() {
	printf "\033[36m========> %s\033[0m\n" "$1"
}

warn() {
	printf "\033[33m========> %s\033[0m\n" "$1"
}

FATE_DIR="$(pwd)/fate"
GITHUB_URL="git@github.com:aosasona/fate.git"

if [ "$USE_HTTP" = 1 ]; then
	GITHUB_URL="https://github.com/aosasona/fate.git"
fi

# If it is not running on Linux then exit
if [ "$(uname)" != "Linux" ]; then
	echo "This script only works on Linux."
	exit 1
fi

# if the RUN_DIRTY environment variable is set to 1, skip the cleanup and cloning of the repo

if [ "$RUN_DIRTY" = 1 ]; then
	warn "Skipping cleanup and cloning of the repo..."
else
	# check if `raw` folder exists in the `fate` dir and clean it out if it does
	if [ -d "$FATE_DIR/raw" ]; then
		log "Cleaning out raw folder..."
		rm -rf "$FATE_DIR/raw" || exit 1
	fi

	# check if flag to clone the repo is set
	log "Cloning Fate..."
	git clone "$GITHUB_URL" "$FATE_DIR/raw" || exit 1
fi

# check if docker is installed or install it
if ! [ -x "$(command -v docker)" ]; then
	warn "Docker is not installed. Installing docker..."
	curl -fsSL https://get.docker.com | sh || exit 1
fi

# check if nixpack is installed or install it
if ! [ -x "$(command -v nixpacks)" ]; then
	warn "Nixpack is not installed. Installing nixpack..."
	curl -sSL https://nixpacks.com/install.sh | bash || exit 1
fi

# check if swarm is already initialized before initializing it
if docker info | grep -q "Swarm: active"; then
	warn "Swarm is already initialized."
else
	log "Initializing swarm..."
	ADDR=$(hostname -I | awk '{print $1}')
	# stop the script if the swarm init fails
	docker swarm init --advertise-addr "$ADDR" || exit 1
fi

# this function will be used to create volumes if they don't exist already
create_volume_or_continue() {
	if docker volume inspect "$1" >/dev/null 2>&1; then
		warn "$1 volume already exists."
	else
		log "Creating $1 volume..."
		docker volume create "$1" || exit 1
	fi
}
#
# # create the required volumes
create_volume_or_continue caddy_data
create_volume_or_continue caddy_config

# check if the setup folder exists in the `fate` dir
if [ -d "$FATE_DIR/setup" ]; then
	log "Setup folder already exists."
else
	log "Creating setup folder..."
	mkdir "$FATE_DIR/setup" || exit 1
fi

# check if the following files exist in the `setup` folder: docker-compose.yml, .env
# if they don't, copy them from the `raw` folder, and exit so that the user can fill in the required values in the .env file and the `fatepg.pem` file
if [ -f "$FATE_DIR/setup/.env" ]; then
	log ".env already exists, skipping..."
	# copy the docker-compose.yml file from the raw folder to the setup folder to make sure it is up to date
	rm "$FATE_DIR/setup/docker-compose.yml" || exit 1
	cp "$FATE_DIR/raw/docker-compose.yml" "$FATE_DIR/setup/docker-compose.yml" || exit 1
else
	cp "$FATE_DIR/raw/docker-compose.yml" "$FATE_DIR/setup/docker-compose.yml" || exit 1
	log "Copying docker-compose.yml and .env..."
	cp "$FATE_DIR/raw/.env.example" "$FATE_DIR/setup/.env" || exit 1
	warn "Please fill in the required values in the .env file and create a fatepg.pem file (or whatever file you set as GH_APP_KEY_PATH in your .env file) for the Github app in $FATE_DIR/setup.
	Note that if you change the name of the file, you will have to change the value of GH_APP_KEY_PATH in your .env file to match the new name and in the docker-compose.yml file, it is recommended to not just use the fatepg.pem name
	After that, run the command again from the initial directory you ran it i.e cd ../../setup or it will fail.
	You can use the environment variable RUN_DIRTY to skip the cleanup and cloning process => curl -fsSL https://aosasona.github.io/fate/setup.sh | RUN_DIRTY=1 sh"
	exit 1
fi

# check if Caddyfile exists, if not create it and provide the default config in the setup folder
if [ -f "$FATE_DIR/setup/Caddyfile" ]; then
	warn "Caddyfile already exists."
else
	log "Creating Caddyfile..."

	# replace the values here in the config with the values in the .env file
	# load email from .env file
	EMAIL=$(grep ACME_EMAIL "$FATE_DIR/setup/.env" | cut -d '=' -f2)
	FATE_PORT=$(grep PORT "$FATE_DIR/setup/.env" | cut -d '=' -f2)

	CONFIG="{
  debug
  auto_https ignore_loaded_certs
  email $EMAIL
  on_demand_tls {
    ask http://fate:$FATE_PORT/ask
  }
  admin 0.0.0.0:2019
}"

	# Write the configuration to the Caddyfile
	echo "$CONFIG" >"$FATE_DIR/setup/Caddyfile"
fi

# check for the presence of the `.data` folder in the `fate` dir, if not, create it and copy `data` and `presets` folders from the `raw` folder
if [ -d "$FATE_DIR/.data" ]; then
	warn ".data folder already exists."
else
	log "Creating .data folder..."
	mkdir "$FATE_DIR/.data" || exit 1
	log "Copying data and presets folders..."
	cp -r "$FATE_DIR/raw/data" "$FATE_DIR/.data/data" || exit 1
	cp -r "$FATE_DIR/raw/presets" "$FATE_DIR/.data/presets" || exit 1
fi

# start the services from the docker-compose file in the `setup` folder, this will pull the images and start the services, essentially working as an updater too
log "Starting services..."
cd "$FATE_DIR/setup" && docker compose pull && docker-compose up -d --build || exit 1

# clean up the `raw` folder
log "Cleaning up..."
rm -rf "$FATE_DIR/raw" || exit 1
