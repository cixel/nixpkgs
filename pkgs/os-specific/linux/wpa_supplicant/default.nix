{stdenv, fetchurl, openssl, qt4, inkscape, dbus_libs, pkgconfig}:

let
  version = "0.7.3";
  src = fetchurl {
    url = "http://hostap.epitest.fi/releases/wpa_supplicant-${version}.tar.gz";
    sha256 = "0hwlsn512q2ps8wxxjmkjfdg3vjqqb9mxnnwfv1wqijkm3551kfh";
  };
in

(stdenv.mkDerivation rec {
  name = "wpa_supplicant-${version}";
  inherit src;

  preBuild = ''
    cd wpa_supplicant
    cp -v defconfig .config
    echo CONFIG_DEBUG_SYSLOG=y | tee -a .config
    echo CONFIG_CTRL_IFACE_DBUS=y | tee -a .config
    echo CONFIG_CTRL_IFACE_DBUS_NEW=y | tee -a .config
    echo CONFIG_CTRL_IFACE_DBUS_INTRO=y | tee -a .config
    substituteInPlace Makefile --replace /usr/local $out
  '';

  buildInputs = [openssl dbus_libs];

  buildNativeInputs = [ pkgconfig ];

  # Upstream patch required for NetworkManager-0.9
  patches = [ (fetchurl {
    url = "http://w1.fi/gitweb/gitweb.cgi?p=hostap-07.git;a=commitdiff_plain;h=b80b5639935d37b95d00f86b57f2844a9c775f57";
    name = "wpa_supplicant-nm-0.9.patch";
    sha256 = "1pqba0l4rfhba5qafvvbywi9x1qmphs944p704bh1flnx7cz6ya8";
    }) ];

  postInstall = ''
    ensureDir $out/share/man/man5 $out/share/man/man8
    cp -v doc/docbook/*.5 $out/share/man/man5/
    cp -v doc/docbook/*.8 $out/share/man/man8/
  '';

  meta = {
    homepage = http://hostap.epitest.fi/wpa_supplicant/;
    description = "A tool for connecting to WPA and WPA2-protected wireless networks";
    maintainers = with stdenv.lib.maintainers; [marcweber urkud];
    platforms = stdenv.lib.platforms.linux;
  };
}) // {
gui = stdenv.mkDerivation {
  name = "wpa_gui-${version}";

  inherit src;

  buildInputs = [ qt4 ];

  buildNativeInputs = [ inkscape ];

  prePatch = "cd wpa_supplicant/wpa_gui-qt4";

  configurePhase = ''
    lrelease wpa_gui.pro
    qmake'';

# We do not install .xpm icons. First of all, I don't know where they should
# be install. Second, this allows us to drop imagemagick build-time dependency.
  postBuild = ''
    sed -e '/ICONS.*xpm/d' -i icons/Makefile
    make -C icons
  '';

  installPhase = ''
    mkdir -pv $out/bin
    cp -v wpa_gui $out/bin
    mkdir -pv $out/share/applications
    cp -v wpa_gui.desktop $out/share/applications
    mkdir -pv $out/share/icons
    cp -av icons/hicolor $out/share/icons
  '';
};
}
