# scripts/setup/banner.sh
# Banner and intro output for setup wizard.

print_banner() {
    echo
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
  ┌───────────────────────────────────────────────────┐
  │                                                   │
  │    m a t r i x - e a s y - d e p l o y - k i t    │
  │                                                   │
  │     Your Matrix homeserver, easily deployed.      │
  │                                                   │
  └───────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  This wizard will set up ${BOLD}Synapse${RESET} + ${BOLD}Caddy${RESET} on this machine (Element is optional)."
    echo -e "  It should take about ${CYAN}5 minutes${RESET}.\n"
}
