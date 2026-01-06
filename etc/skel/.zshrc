# Plugins
plugins=(git command-not-found systemd)

# User configuration

if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
    source /etc/profile.d/vte.sh
fi


