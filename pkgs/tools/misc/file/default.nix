{ stdenv, fetchurl, file, zlib }:

stdenv.mkDerivation rec {
  name = "file-${version}";
  version = "5.32";

  src = fetchurl {
    urls = [
      "ftp://ftp.astron.com/pub/file/${name}.tar.gz"
      "https://distfiles.macports.org/file/${name}.tar.gz"
    ];
    sha256 = "0l1bfa0icng9vdwya00ff48fhvjazi5610ylbhl35qi13d6xqfc6";
  };

  nativeBuildInputs = stdenv.lib.optional (stdenv.hostPlatform != stdenv.buildPlatform) file;
  buildInputs = [ zlib ];

  patches = [ ./file-5.33-CVE-2018-10360.patch ];

  doCheck = true;


  meta = with stdenv.lib; {
    homepage = http://darwinsys.com/file;
    description = "A program that shows the type of files";
    license = licenses.bsd2;
    platforms = platforms.all;
  };
}
