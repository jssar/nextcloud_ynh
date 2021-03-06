#
# Common variables
#

APPNAME="nextcloud"

# Nextcloud version
VERSION="10.0.1"

# Package name for Nextcloud dependencies
DEPS_PKG_NAME="nextcloud-deps"

# Remote URL to fetch Nextcloud tarball
NEXTCLOUD_SOURCE_URL="https://download.nextcloud.com/server/releases/nextcloud-${VERSION}.tar.bz2"

# Remote URL to fetch Nextcloud tarball checksum
NEXTCLOUD_SOURCE_SHA256="39412a28f02fd7ca8c9267b4ccf02ac28c1eb27995d77c06ceb2699375978b25"

# App package root directory should be the parent folder
PKGDIR=$(cd ../; pwd)

#
# Common helpers
#

# Download and extract Nextcloud sources to the given directory
# usage: extract_nextcloud DESTDIR [AS_USER]
extract_nextcloud() {
  local DESTDIR=$1
  local AS_USER=${2:-admin}

  # retrieve and extract Roundcube tarball
  nc_tarball="/tmp/nextcloud.tar.bz2"
  rm -f "$nc_tarball"
  wget -q -O "$nc_tarball" "$NEXTCLOUD_SOURCE_URL" \
    || ynh_die "Unable to download Nextcloud tarball"
  echo "$NEXTCLOUD_SOURCE_SHA256 $nc_tarball" | sha256sum -c >/dev/null \
    || ynh_die "Invalid checksum of downloaded tarball"
  exec_as "$AS_USER" tar xjf "$nc_tarball" -C "$DESTDIR" --strip-components 1 \
    || ynh_die "Unable to extract Nextcloud tarball"
  rm -f "$nc_tarball"

  # apply patches
  (cd "$DESTDIR" \
   && for p in ${PKGDIR}/patches/*.patch; do \
        exec_as "$AS_USER" patch -p1 < $p; done) \
    || ynh_die "Unable to apply patches to Nextcloud"
}

# Execute a command as another user
# usage: exec_as USER COMMAND [ARG ...]
exec_as() {
  local USER=$1
  shift 1

  if [[ $USER = $(whoami) ]]; then
    eval "$@"
  else
    # use sudo twice to be root and be allowed to use another user
    sudo sudo -u "$USER" "$@"
  fi
}

# Execute a command with occ as a given user from a given directory
# usage: exec_occ WORKDIR AS_USER COMMAND [ARG ...]
exec_occ() {
  local WORKDIR=$1
  local AS_USER=$2
  shift 2

  (cd "$WORKDIR" && exec_as "$AS_USER" \
      php occ --no-interaction --no-ansi "$@")
}

# Create the external storage for the home folders and enable sharing
# usage: create_home_external_storage OCC_COMMAND
create_home_external_storage() {
  local OCC=$1
  local mount_id=`$OCC files_external:create --output=json \
      'Home' 'local' 'null::null' -c 'datadir=/home/$user' || true`
  ! [[ $mount_id =~ ^[0-9]+$ ]] \
    && echo "Unable to create external storage" 1>&2 \
    || $OCC files_external:option "$mount_id" enable_sharing true
}

# Check if an URL is already handled
# usage: is_url_handled URL
is_url_handled() {
  local OUTPUT=($(curl -k -s -o /dev/null \
      -w 'x%{redirect_url} %{http_code}' "$1"))
  # it's handled if it does not redirect to the SSO nor return 404
  [[ ! ${OUTPUT[0]} =~ \/yunohost\/sso\/ && ${OUTPUT[1]} != 404 ]]
}

# Rename a MySQL database and user
# usage: rename_mysql_db DBNAME DBUSER DBPASS NEW_DBNAME NEW_DBUSER
rename_mysql_db() {
  local DBNAME=$1 DBUSER=$2 DBPASS=$3 NEW_DBNAME=$4 NEW_DBUSER=$5
  local SQLPATH="/tmp/${DBNAME}-$(date '+%s').sql"

  # dump the old database
  mysqldump -u "$DBUSER" -p"$DBPASS" --no-create-db "$DBNAME" > "$SQLPATH"
  # create the new database and user
  ynh_mysql_create_db "$NEW_DBNAME" "$NEW_DBUSER" "$DBPASS"
  ynh_mysql_connect_as "$NEW_DBUSER" "$DBPASS" "$NEW_DBNAME" < "$SQLPATH"
  # remove the old database
  ynh_mysql_drop_db "$DBNAME"
  ynh_mysql_drop_user "$DBUSER"
  rm "$SQLPATH"
}
