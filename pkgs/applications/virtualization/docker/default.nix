{ stdenv, lib, fetchFromGitHub, makeWrapper, removeReferencesTo, pkgconfig
, go-md2man, go, containerd, runc, docker-proxy, tini, libtool
, sqlite, iproute, bridge-utils, devicemapper, systemd
, btrfs-progs, iptables, e2fsprogs, xz, utillinux, xfsprogs
, procps, libseccomp
}:

with lib;

rec {
  dockerGen = {
      version, rev, sha256
      , runcRev, runcSha256
      , containerdRev, containerdSha256
      , tiniRev, tiniSha256
    } :
  let
    docker-runc = runc.overrideAttrs (oldAttrs: rec {
      name = "docker-runc";
      src = fetchFromGitHub {
        owner = "docker";
        repo = "runc";
        rev = runcRev;
        sha256 = runcSha256;
      };
      # docker/runc already include these patches / are not applicable
      patches = [];
    });

    docker-containerd = (containerd.override { inherit go; }).overrideAttrs (oldAttrs: rec {
      name = "docker-containerd";
      src = fetchFromGitHub {
        owner = "docker";
        repo = "containerd";
        rev = containerdRev;
        sha256 = containerdSha256;
      };

      hardeningDisable = [ "fortify" ];

      buildInputs = [ removeReferencesTo go btrfs-progs ];
    });

    docker-tini = tini.overrideAttrs  (oldAttrs: rec {
      name = "docker-init";
      src = fetchFromGitHub {
        owner = "krallin";
        repo = "tini";
        rev = tiniRev;
        sha256 = tiniSha256;
      };

      # Do not remove static from make files as we want a static binary
      patchPhase = ''
      '';

      NIX_CFLAGS_COMPILE = [
        "-DMINIMAL=ON"
      ];
    });
  in
    stdenv.mkDerivation ((optionalAttrs (stdenv.isLinux) rec {

    inherit docker-runc docker-containerd docker-proxy docker-tini;

    DOCKER_BUILDTAGS = []
      ++ optional (systemd != null) [ "journald" ]
      ++ optional (btrfs-progs == null) "exclude_graphdriver_btrfs"
      ++ optional (devicemapper == null) "exclude_graphdriver_devicemapper"
      ++ optional (libseccomp != null) "seccomp";

   }) // rec {
    inherit version rev;

    name = "docker-${version}";

    src = fetchFromGitHub {
      owner = "docker";
      repo = "docker-ce";
      rev = "v${version}";
      sha256 = sha256;
    };

    # Optimizations break compilation of libseccomp c bindings
    hardeningDisable = [ "fortify" ];

    nativeBuildInputs = [ pkgconfig ];
    buildInputs = [
      makeWrapper removeReferencesTo go-md2man go libtool
    ] ++ optionals (stdenv.isLinux) [
      sqlite devicemapper btrfs-progs systemd libseccomp
    ];

    dontStrip = true;

    buildPhase = (optionalString (stdenv.isLinux) ''
      # build engine
      cd ./components/engine
      export AUTO_GOPATH=1
      export DOCKER_GITCOMMIT="${rev}"
      export VERSION="${version}"
      ./hack/make.sh dynbinary
      cd -
    '') + ''
      # build cli
      cd ./components/cli
      # Mimic AUTO_GOPATH
      mkdir -p .gopath/src/github.com/docker/
      ln -sf $PWD .gopath/src/github.com/docker/cli
      export GOPATH="$PWD/.gopath:$GOPATH"
      export GITCOMMIT="${rev}"
      export VERSION="${version}"
      source ./scripts/build/.variables
      export CGO_ENABLED=1
      go build -tags pkcs11 --ldflags "$LDFLAGS" github.com/docker/cli/cmd/docker
      cd -
    '';

    # systemd 230 no longer has libsystemd-journal as a separate entity from libsystemd
    patchPhase = ''
      substituteInPlace ./components/cli/scripts/build/.variables --replace "set -eu" ""
    '' + optionalString (stdenv.isLinux) ''
      patchShebangs .
      substituteInPlace ./components/engine/hack/make.sh                   --replace libsystemd-journal libsystemd
      substituteInPlace ./components/engine/daemon/logger/journald/read.go --replace libsystemd-journal libsystemd
    '';

    outputs = ["out" "man"];

    extraPath = optionals (stdenv.isLinux) (makeBinPath [ iproute iptables e2fsprogs xz xfsprogs procps utillinux ]);

    installPhase = optionalString (stdenv.isLinux) ''
      install -Dm755 ./components/engine/bundles/dynbinary-daemon/dockerd $out/libexec/docker/dockerd

      makeWrapper $out/libexec/docker/dockerd $out/bin/dockerd \
        --prefix PATH : "$out/libexec/docker:$extraPath"

      # docker uses containerd now
      ln -s ${docker-containerd}/bin/containerd $out/libexec/docker/docker-containerd
      ln -s ${docker-containerd}/bin/containerd-shim $out/libexec/docker/docker-containerd-shim
      ln -s ${docker-runc}/bin/runc $out/libexec/docker/docker-runc
      ln -s ${docker-proxy}/bin/docker-proxy $out/libexec/docker/docker-proxy
      ln -s ${docker-tini}/bin/tini-static $out/libexec/docker/docker-init

      # systemd
      install -Dm644 ./components/engine/contrib/init/systemd/docker.service $out/etc/systemd/system/docker.service
    '' + ''
      install -Dm755 ./components/cli/docker $out/libexec/docker/docker

      makeWrapper $out/libexec/docker/docker $out/bin/docker \
        --prefix PATH : "$out/libexec/docker:$extraPath"

      # completion (cli)
      install -Dm644 ./components/cli/contrib/completion/bash/docker $out/share/bash-completion/completions/docker
      install -Dm644 ./components/cli/contrib/completion/fish/docker.fish $out/share/fish/vendor_completions.d/docker.fish
      install -Dm644 ./components/cli/contrib/completion/zsh/_docker $out/share/zsh/site-functions/_docker

      # Include contributed man pages (cli)
      # Generate man pages from cobra commands
      echo "Generate man pages from cobra"
      cd ./components/cli
      mkdir -p ./man/man1
      go build -o ./gen-manpages github.com/docker/cli/man
      ./gen-manpages --root . --target ./man/man1

      # Generate legacy pages from markdown
      echo "Generate legacy manpages"
      ./man/md2man-all.sh -q

      manRoot="$man/share/man"
      mkdir -p "$manRoot"
      for manDir in ./man/man?; do
        manBase="$(basename "$manDir")" # "man1"
        for manFile in "$manDir"/*; do
          manName="$(basename "$manFile")" # "docker-build.1"
          mkdir -p "$manRoot/$manBase"
          gzip -c "$manFile" > "$manRoot/$manBase/$manName.gz"
        done
      done
    '';

    preFixup = ''
      find $out -type f -exec remove-references-to -t ${go} -t ${stdenv.cc.cc} '{}' +
    '' + optionalString (stdenv.isLinux) ''
      find $out -type f -exec remove-references-to -t ${stdenv.glibc.dev} '{}' +
    '';

    meta = {
      homepage = https://www.docker.com/;
      description = "An open source project to pack, ship and run any application as a lightweight container";
      license = licenses.asl20;
      maintainers = with maintainers; [ nequissimus offline tailhook vdemeester periklis ];
      platforms = with platforms; linux ++ darwin;
    };
  });

  # Get revisions from
  # https://github.com/docker/docker-ce/tree/v${version}/components/engine/hack/dockerfile/install/*

  docker_18_06 = dockerGen rec {
    version = "18.06.0-ce";
    rev = "0ffa8257ec673ed6849b73b03fb01b0cac90fdb3"; # git commit
    sha256 = "1w6jgqbc53pkgfkf2p6z5g316q1r5jvnw4lq11j4qdkw7vy8q5d9";
    runcRev = "69663f0bd4b60df09991c08812a60108003fa340";
    runcSha256 = "1l37r97l3ra4ph069w190d05r0a43s76nn9jvvlkbwrip1cp6gyq";
    containerdRev = "d64c661f1d51c48782c9cec8fda7604785f93587";
    containerdSha256 = "0pk1kii8bmlvziblrqwb88w5cd486pmb7vw8p7kcyn9lqsw32ria";
    tiniRev = "fec3683b971d9c3ef73f284f176672c44b448662";
    tiniSha256 = "1h20i3wwlbd8x4jr2gz68hgklh0lb0jj7y5xk1wvr8y58fip1rdn";
  };
}
