#!/usr/bin/env bash

# Set bash to fail immediately if any command fails
set -euo pipefail

# Configuration files
apt_packages_file="$HOME/.config/packages.apt"
apt_repos_file="$HOME/.config/repositories.apt"
snap_packages_file="$HOME/.config/packages.snap"
pip_packages_file="$HOME/.config/packages.pip"
git_repos_file="$HOME/.config/repositories.git"
github_releases_file="$HOME/.config/releases.github"

# Logging configuration
LOGFILE="/var/log/package_setup.log"

###################
# Helper Functions
###################

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | sudo tee -a "$LOGFILE"
}

error_exit() {
  log "ERROR: $1" >&2
  exit 1
}

check_not_root() {
  if [[ "$EUID" -eq 0 ]]; then
    error_exit "Please run as a normal user, not root."
  fi
}

check_required_files() {
  if [[ ! -f "$apt_packages_file" ]] && [[ ! -f "$snap_packages_file" ]] && [[ ! -f "$pip_packages_file" ]]; then
    log "No package files found. Exiting."
    exit 1
  fi
}

install_base_dependencies() {
  log "📦 Installing base dependencies..."
  sudo apt update
  sudo apt install -y software-properties-common apt-utils curl wget git
}

ensure_command() {
  local cmd="$1"
  local package="$2"

  if ! command -v "$cmd" &>/dev/null; then
    log "Installing $package..."
    sudo apt install -y "$package"
  fi
}

###################
# Package Management Functions
###################

add_apt_repositories() {
  if [[ ! -f "$apt_repos_file" ]]; then
    log "No repository file found at $apt_repos_file"
    return
  fi

  log "📦 Adding APT repositories from $apt_repos_file..."
  sudo dpkg --add-architecture i386

  repos=$(grep -vE '^\s*#' "$apt_repos_file" | grep -vE '^\s*$')

  if [[ -n "$repos" ]]; then
    while IFS= read -r repo; do
      log "Adding repository: $repo"
      sudo add-apt-repository -y "$repo"
    done <<<"$repos"
    sudo apt update
  else
    log "No repositories to add."
  fi
}

install_apt_packages() {
  if [[ ! -f "$apt_packages_file" ]]; then
    log "No APT packages file found at $apt_packages_file"
    return
  fi

  apt_packages=$(grep -vE '^\s*#' "$apt_packages_file" | grep -vE '^\s*$')

  if [[ -n "$apt_packages" ]]; then
    log "📦 Installing APT packages from $apt_packages_file..."
    echo "$apt_packages" | xargs sudo apt install -y
  else
    log "No APT packages to install."
  fi
}

install_snap_packages() {
  if [[ ! -f "$snap_packages_file" ]]; then
    log "No SNAP packages file found at $snap_packages_file"
    return
  fi

  snap_packages=$(grep -vE '^\s*#' "$snap_packages_file" | grep -vE '^\s*$')

  if [[ -n "$snap_packages" ]]; then
    log "📦 Installing SNAP packages from $snap_packages_file..."
    while IFS= read -r package; do
      # Check if the snap package has installation flags (classic, etc.)
      if [[ $package == *"--"* ]]; then
        package_name=$(echo "$package" | cut -d' ' -f1)
        flags=$(echo "$package" | cut -d' ' -f2-)
        log "Installing snap package $package_name with flags: $flags"
        sudo snap install "$package_name" $flags
      else
        log "Installing snap package $package"
        sudo snap install "$package"
      fi
    done <<<"$snap_packages"
  else
    log "No SNAP packages to install."
  fi
}

install_pip_packages() {
  if [[ ! -f "$pip_packages_file" ]]; then
    log "No PIP packages file found at $pip_packages_file"
    return
  fi

  pip_packages=$(grep -vE '^\s*#' "$pip_packages_file" | grep -vE '^\s*$')

  if [[ -n "$pip_packages" ]]; then
    log "📦 Installing PIP packages from $pip_packages_file..."
    # Ensure pipx is installed
    ensure_command "pipx" "pipx"

    # Ensure pipx bins are in PATH
    pipx ensurepath

    while IFS= read -r package; do
      log "Installing pip package: $package"
      pipx install "$package"
    done <<<"$pip_packages"
  else
    log "No PIP packages to install."
  fi
}

process_git_repositories() {
  if [[ ! -f "$git_repos_file" ]]; then
    log "No Git repositories file found at $git_repos_file"
    return
  fi

  git_repos=$(grep -vE '^\s*#' "$git_repos_file" | grep -vE '^\s*$')

  if [[ -n "$git_repos" ]]; then
    log "📦 Processing Git repositories from $git_repos_file..."
    # Ensure git is installed
    ensure_command "git" "git"

    # Create downloads directory if it doesn't exist
    DOWNLOADS_DIR="$HOME/Downloads/git-repos"
    mkdir -p "$DOWNLOADS_DIR"

    while IFS= read -r line; do
      # Format: repo_url|directory_name|install_command
      IFS='|' read -r repo_url dir_name install_command <<<"$line"

      if [[ -z "$dir_name" ]]; then
        dir_name=$(basename "$repo_url" .git)
      fi

      target_dir="$DOWNLOADS_DIR/$dir_name"
      log "Cloning $repo_url to $target_dir"

      # Check if target directory exists and handle it appropriately
      if [[ -d "$target_dir" ]]; then
        if [[ -d "$target_dir/.git" ]]; then
          log "Repository already exists at $target_dir, updating instead of cloning..."
          cd "$target_dir"
          git fetch --all
          git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
          git pull
        else
          log "Directory exists but is not a git repository, removing and cloning fresh..."
          rm -rf "$target_dir"
          mkdir -p "$target_dir"
          git clone "$repo_url" "$target_dir"
        fi
      else
        mkdir -p "$target_dir"
        git clone "$repo_url" "$target_dir"
      fi

      if [[ -n "$install_command" ]]; then
        log "Running install command for $dir_name"
        cd "$target_dir"
        eval "$install_command"
      fi
    done <<<"$git_repos"
  else
    log "No Git repositories to process."
  fi
}

install_latest_github_release() {
  local repo="$1"    # Format: "owner/repo"
  local pattern="$2" # Regex pattern to match desired asset (e.g., ".*\.deb")
  local name="$3"    # Human-readable name for logging

  log "📦 Installing latest $name release from GitHub ($repo)..."

  # Create temporary directory
  local temp_dir=$(mktemp -d)
  cd "$temp_dir"

  # Fetch latest release info
  log "Fetching latest release information for $repo"
  local release_info
  if ! release_info=$(curl -s "https://api.github.com/repos/$repo/releases/latest"); then
    log "Failed to fetch release information for $repo"
    cd - >/dev/null
    rm -rf "$temp_dir"
    return 1
  fi

  # Extract download URL for the matching asset
  local download_url
  download_url=$(echo "$release_info" | grep -o "\"browser_download_url\": \"[^\"]*$pattern\"" | head -n 1 | cut -d'"' -f4)

  if [[ -z "$download_url" ]]; then
    log "No matching asset found for $repo with pattern: $pattern"
    cd - >/dev/null
    rm -rf "$temp_dir"
    return 1
  fi

  # Extract version for logging
  local version
  version=$(echo "$release_info" | grep -o "\"tag_name\": \"[^\"]*\"" | cut -d'"' -f4)
  log "Found version $version"

  # Download the asset
  local filename=$(basename "$download_url")
  log "Downloading $filename from $download_url"
  if ! curl -L -o "$filename" "$download_url"; then
    log "Failed to download $filename"
    cd - >/dev/null
    rm -rf "$temp_dir"
    return 1
  fi

  # Install the .deb package
  log "Installing $filename"
  if ! sudo apt install -y "./$filename"; then
    log "Failed to install $filename"
    cd - >/dev/null
    rm -rf "$temp_dir"
    return 1
  fi

  # Clean up
  cd - >/dev/null
  rm -rf "$temp_dir"
  log "Successfully installed $name $version"
}

process_github_releases() {
  if [[ ! -f "$github_releases_file" ]]; then
    log "No GitHub releases file found at $github_releases_file"
    return
  fi

  github_releases=$(grep -vE '^\s*#' "$github_releases_file" | grep -vE '^\s*$')

  if [[ -n "$github_releases" ]]; then
    log "📦 Processing GitHub releases from $github_releases_file..."

    # Ensure curl is installed
    ensure_command "curl" "curl"

    while IFS= read -r line; do
      # Format: repo|pattern|name
      IFS='|' read -r repo pattern name <<<"$line"

      if [[ -z "$name" ]]; then
        name=$(echo "$repo" | cut -d'/' -f2)
      fi

      if [[ -z "$pattern" ]]; then
        pattern=".*\.deb"
      fi

      install_latest_github_release "$repo" "$pattern" "$name"
    done <<<"$github_releases"
  else
    log "No GitHub releases to process."
  fi
}

perform_special_setup() {
  log "Performing additional setup tasks..."

  # Verify if Streamdeck UI is in pip packages and set up accordingly
  if [[ -f "$pip_packages_file" ]] && grep -q "streamdeck_ui" "$pip_packages_file"; then
    log "🖲️ Setting up Streamdeck UI..."
    # Ensure dependencies are installed
    sudo apt install -y libhidapi-libusb0 libudev-dev
    log "Streamdeck UI setup completed. Launch with 'streamdeck' after reboot."
  fi
}

cleanup() {
  log "🧹 Cleaning up..."
  sudo apt autoremove -y
}

###################
# Main Execution
###################

main() {
  check_not_root
  log "✅ Starting package installation setup..."
  check_required_files
  install_base_dependencies
  add_apt_repositories
  install_apt_packages
  install_snap_packages
  install_pip_packages
  process_git_repositories
  process_github_releases
  perform_special_setup
  cleanup

  log "🎉 Setup complete! Review $LOGFILE for details."
  echo -e "\n✅ All done! Please REBOOT your system to finalize everything."
}

# Execute main function
main
