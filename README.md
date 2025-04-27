# quick-and-dirty-packages

1. `git clone https://github.com/trackballenjoyer/quick-and-dirty-packages.git`
2. `cd quick-and-dirty-packages`
3. `chmod +x ./install-packages.sh`
4. Create one or more of the following files with your desired contents:
   - [packages.apt](packages.apt)
   - [releases.github](releases.github)
   - [repositories.apt](releases.github)
5. Run the package installer: `./install-packages.sh`

## Package file examples

### packages.apt

Install apt packages

```txt
wget
curl
git
gnupg
build-essential
steam-installer
steam-devices
streamdeck-ui
terminfo
winetricks
helvum
obs-studio
python3-pip

# streamdeck_ui dependencies
libhidapi-dev
libhidapi-libusb0
libudev-dev
libjpeg-dev
zlib1g-dev
libpng-dev
libtiff-dev
libfreetype6-dev
protontricks
```

### repositories.apt

Add apt repositories.

```txt
ppa:obsproject/obs-studio
```

### releases.github

Download GitHub releases and install them.

```txt
# Format: repo|pattern|name
GoXLR-on-Linux/goxlr-utility|.*amd64\.deb|GoXLR Utility
```
