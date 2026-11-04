#!/bin/bash
set -euxo pipefail

# Stop the default PostgreSQL cluster on the runner if it exists
sudo -u postgres pg_dropcluster 16 main --stop || true
# Install PostgreSQL. The runner image already has all of its dependencies,
# so read only the package list of the PostgreSQL repository. A separate
# lists directory keeps apt from parsing the package lists of the image.
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo mkdir -p /var/lib/apt/pgdg-lists/partial
apt_options=(-o Dir::Etc::sourcelist=sources.list.d/pgdg.list -o Dir::Etc::sourceparts=- -o Dir::State::Lists=/var/lib/apt/pgdg-lists -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
sudo apt-get update "${apt_options[@]}"
# The test database does not need to survive a crash, so skip the syncs of
# dpkg and initdb
echo "initdb_options = '--no-sync'" | sudo tee -a /etc/postgresql-common/createcluster.conf > /dev/null
sudo NEEDRESTART_SUSPEND=1 apt-get install -y "${apt_options[@]}" -o Dpkg::Options::=--force-unsafe-io postgresql-17 postgresql-client-17
# Allow runner and postgres users to access PostgreSQL
echo 'runner_map postgres postgres
runner_map runner postgres
runner_map runner clover
runner_map runner clover_password' | sudo tee -a /etc/postgresql/17/main/pg_ident.conf > /dev/null
sudo sed -i '1i local   all   all   peer map=runner_map' /etc/postgresql/17/main/pg_hba.conf
echo 'fsync = off
synchronous_commit = off
full_page_writes = off' | sudo tee /etc/postgresql/17/main/conf.d/ci.conf > /dev/null
# Start the server with pg_ctl. The startup check of pg_ctlcluster sleeps
# for at least 2 seconds.
sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl start -w -s \
  -D /var/lib/postgresql/17/main \
  -l /var/log/postgresql/postgresql-17-main.log \
  -o "-c config_file=/etc/postgresql/17/main/postgresql.conf"
