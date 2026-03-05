# scripts/setup/modules.sh
# Module setup dispatcher for setup.sh --module.

run_module_setup() {
    local module="$1"
    local module_script="${SCRIPT_DIR}/modules/${module}/setup.sh"

    if [[ ! -f "$module_script" ]]; then
        die "Module '${module}' not found. Expected: ${module_script}"
    fi

    info "Running setup for module: ${module}"
    bash "$module_script"
}
