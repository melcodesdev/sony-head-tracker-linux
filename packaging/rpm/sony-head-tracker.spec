# RPM spec for Fedora COPR and openSUSE OBS (dnf / zypper repos).
#
# COPR (recommended, open signup): create a project at copr.fedorainfracloud.org,
# add a package with the SCM build method (Type: git, Clone URL: this repo,
# Spec File: packaging/rpm/sony-head-tracker.spec, Source build method: rpkg).
# Users then:  sudo dnf copr enable melcodesdev/sony-head-tracker
#              sudo dnf install sony-head-tracker
#
# Bump Version to match the release tag. rpkg/COPR generate the source tarball
# from the git checkout, so Source0 below is a plain fallback for local rpmbuild.
Name:           sony-head-tracker
Version:        2.2.0
Release:        1%{?dist}
Summary:        Use Sony headphones as a head tracker for OpenTrack

License:        MIT
URL:            https://github.com/melcodesdev/sony-head-tracker-linux
Source0:        %{url}/archive/refs/heads/main.tar.gz#/%{name}-%{version}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  make
Requires:       gtk4
Requires:       libadwaita
Requires:       python3
Requires:       python3-gobject
Recommends:     opentrack

%description
Turns compatible Sony Bluetooth headphones into a real-time head tracker for
OpenTrack and other applications, with a command-line bridge and a GTK desktop
app. It reads the Android Head Tracker HID sensor the headset exposes and streams
yaw/pitch/roll over loopback UDP. Linux port of Nicholas Slattery's Sony Head
Tracker.

%prep
# The GitHub archive unpacks to sony-head-tracker-linux-<ref>; COPR/rpkg name the
# tarball to match %%{name}-%%{version}. Use -c -n so either layout works.
%autosetup -c -n %{name}-%{version}
# If the tree landed one directory deep (GitHub archive), hoist it.
if [ -d sony-head-tracker-linux-* ]; then mv sony-head-tracker-linux-*/* . 2>/dev/null || true; fi

%build
make %{?_smp_mflags}

%install
make install DESTDIR=%{buildroot} PREFIX=%{_prefix}

%post
udevadm control --reload-rules 2>/dev/null || :
udevadm trigger 2>/dev/null || :

%files
%license LICENSE
%doc README.md docs/LINUX.md
%{_bindir}/sony-head-tracker
%{_bindir}/sony-head-tracker-gui
%{_bindir}/sony-head-tracker-recenter
%{_prefix}/lib/udev/rules.d/70-sony-head-tracker.rules
%{_datadir}/applications/io.github.sonyheadtracker.desktop
%{_datadir}/icons/hicolor/scalable/apps/io.github.sonyheadtracker.svg
%dir %{_datadir}/sony-head-tracker
%{_datadir}/sony-head-tracker/

%changelog
* Mon Jul 13 2026 melcodesdev <melcodesdev@users.noreply.github.com> - 2.2.0-1
- Initial Linux packaging (CLI + GTK app).
