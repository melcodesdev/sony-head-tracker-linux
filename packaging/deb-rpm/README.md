# Debian/Fedora packaging (apt / dnf)

Two ways to get native `.deb` / `.rpm` packages, depending on whether you want
downloadable files or a real repo users can `apt install` / `dnf install` by name.

## Option A: downloadable .deb and .rpm files (quickest)

`build-packages.sh` turns `make install` into both packages with `fpm`.

```bash
# one-time: install fpm (needs ruby)
sudo pacman -S ruby            # Arch/CachyOS  (apt: ruby ruby-dev; dnf: ruby rubygems)
gem install --user-install fpm
export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$PATH"

# build both packages
VERSION=2.2.0 packaging/deb-rpm/build-packages.sh
```

Produces `sony-head-tracker_2.2.0_amd64.deb` and
`sony-head-tracker-2.2.0-1.x86_64.rpm`. Attach them to the GitHub release; users
install with `sudo apt install ./…​.deb` or `sudo dnf install ./…​.rpm`. Not a
repo, but real native packages with correct dependencies and a udev reload hook.

## Option B: hosted repos (proper `apt install` / `dnf install`)

Free build services that host a repo and rebuild when you push. Their signup is
open (unlike the AUR right now).

### Fedora / RHEL (dnf) - COPR

1. Sign in at <https://copr.fedorainfracloud.org> with a Fedora account (FAS).
2. New Project, then a package using the **SCM** build method: Clone URL
   `https://github.com/melcodesdev/sony-head-tracker-linux`, build with `rpkg`
   or point it at an `.spec` (generate one from the `.rpm` above with
   `rpm2cpio`, or write a short spec that runs `make` + `make install`).
3. Users: `sudo dnf copr enable melcodesdev/sony-head-tracker && sudo dnf install sony-head-tracker`.

### Debian/Ubuntu + Fedora together - openSUSE OBS

<https://build.opensuse.org> builds `.deb` **and** `.rpm` for many distros from
one project (a `.spec` plus a `debian/` dir, or a single `_service`). Best
coverage for the least duplication. Users add the repo, then `apt`/`dnf install`.

### Ubuntu only - Launchpad PPA

A `debian/` dir + GPG-signed source upload; users
`add-apt-repository ppa:you/sony-head-tracker`.

## Note

The AppImage on the GitHub release already runs on all of these distros with no
packaging at all; the above is for users who prefer native apt/dnf integration.
