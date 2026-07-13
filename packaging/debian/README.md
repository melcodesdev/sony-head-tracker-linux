# Debian/Ubuntu packaging (apt install by name)

Standard Debian source packaging for the CLI + GTK app. Use it to publish an apt
repo people add once, then `sudo apt install sony-head-tracker` with updates.

**Toolchain note:** the code needs a C++20 compiler with `std::format`
(g++ 13+). So target **Debian 13 (trixie) or newer** and **Ubuntu 24.04 or
newer**; older releases (Debian 12, Ubuntu 22.04) ship g++ 12 and will fail to
build.

## Option A: openSUSE OBS (recommended, builds many distros)

<https://build.opensuse.org> hosts an apt repo and rebuilds on change; free,
open signup.

1. Sign in, create a project (e.g. `home:melcodesdev`).
2. Create a package `sony-head-tracker`.
3. Add sources: either upload these `debian/` files plus
   `packaging/rpm/sony-head-tracker.spec`, or add a `_service` that pulls the git
   repo. OBS expects `debian/` at the source-tarball root, so if you pull from git,
   arrange the service to place `packaging/debian/` there.
4. In **Repositories**, enable `Debian_Testing`, `xUbuntu_24.04` (and any newer),
   and optionally the Fedora/openSUSE/Arch targets to cover them from one project.
5. Users add the repo (OBS prints the exact lines per distro), then
   `sudo apt update && sudo apt install sony-head-tracker`.

## Option B: Launchpad PPA (Ubuntu only)

1. Copy these files to a top-level `debian/` in a checkout, then:
   ```sh
   sudo apt install devscripts debhelper
   cp -r packaging/debian debian
   debuild -S -sa        # builds a signed source package (needs a GPG key)
   dput ppa:melcodesdev/sony-head-tracker ../sony-head-tracker_*_source.changes
   ```
2. Launchpad builds it; users `sudo add-apt-repository ppa:melcodesdev/sony-head-tracker`.

## Build a plain .deb locally (no repo)

```sh
cp -r packaging/debian debian
sudo apt build-dep .        # or: sudo apt install debhelper g++ make
dpkg-buildpackage -us -uc -b
```
Produces `../sony-head-tracker_2.2.0-1_amd64.deb` for `sudo apt install ./…​.deb`.
