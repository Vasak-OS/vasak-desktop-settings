# Plugins
plugins=(git command-not-found systemd)

# User configuration

if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
    source /etc/profile.d/vte.sh
fi

# Alias definitions

alias cat=bat
alias ls="eza --icons"
alias sudo=sudo-rs
alias grep=rg
alias find=fd
alias du=dust
alias ps=procs
