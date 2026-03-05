# scripts/setup/banner.sh
# Banner and intro output for setup wizard.

print_banner() {
    echo
  echo -e "${BOLD}${GREEN}"
    cat << 'EOF'
  ╔═══════════════════════════════════════════════════╗
  ║     ___  ___  ___ ___________ _______   __        ║
  ║     |  \/  | / _ \_   _| ___ \_   _\ \ / /        ║
  ║     | .  . |/ /_\ \| | | |_/ / | |  \ V /         ║
  ║     | |\/| ||  _  || | |    /  | |  /   \         ║
  ║     | |  | || | | || | | |\ \ _| |_/ /^\ \        ║
  ║     \_|  |_/\_| |_/\_/ \_| \_|\___/\/   \/        ║
  ║                                                   ║
  ║        Easy Deploy Kit  :: Setup Wizard           ║
  ╚═══════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}"
  echo -e "  Control plane for ${BOLD}Synapse${RESET}, ${BOLD}Caddy${RESET}, modules, users, and lifecycle ops."
  echo -e "  Clean defaults. Low noise. ${GREEN}A little hacker signal.${RESET}\n"
}
