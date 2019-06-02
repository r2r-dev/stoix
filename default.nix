{
  nixpkgs ? import (
    fetchTarball {
      name = "nixos-r-tr";
      url = "http://github.com/r-tr/nixpkgs/tarball/master";
      sha256 = "0z8f609cqy6ay40rdwgxkmj0m8h1vhrl79z221d2hm5a0cwwcwc7";
    }
  )
, system ? builtins.currentSystem
, arch ? "x86_64"
}:

let
  nativePkgs = nixpkgs {
    inherit system;
  };
  muslPkgs = (nativePkgs).pkgsMusl;
  staticMuslPkgs = nixpkgs {
    crossOverlays = [ (import "${nativePkgs.path}/pkgs/top-level/static.nix") ];
    crossSystem = {
      config = "${arch}-unknown-linux-musl";
    };
  };

  inherit (nativePkgs) dockerTools gzip;
  inherit (nativePkgs.stdenv) mkDerivation;
  inherit (nativePkgs.lib) concatStringsSep genList;

  statix-runner = nativePkgs.writeScript "statix-runner.sh" ''
    export NIX_DATA_DIR=$PWD/share
    name="$1"
    shift
    exec -a "$name" ./statix "$@"
  '';
  statix = nativePkgs.stdenv.mkDerivation {
    name = "statix";
    phases = [
      "installPhase"
      "fixupPhase"
    ];
    buildInputs = [ nativePkgs.haskellPackages.arx ];
    installPhase = ''
      cp -r ${staticMuslPkgs.nix}/share share
      chmod -R 755 share
      rm -rf share/nix/sandbox
      chmod 644 share/nix/corepkgs/*
      cp ${staticMuslPkgs.nix}/bin/nix-build statix
      chmod 755 statix
      tar -I "gzip --best" -c -f statix.tar.gz statix share/

      mkdir -p $out/bin/
      arx tmpx ./statix.tar.gz -o $out/bin/statix -e ${statix-runner}
      chmod +x $out/bin/statix
    '';
    fixupPhase = ''
      find $out -type f -exec patchelf --shrink-rpath '{}' \; -exec strip '{}' \; 2>/dev/null
    '';
  };

  busyboxMinimal = muslPkgs.busybox.override {
    useMusl = true;
    enableStatic = true;
    enableMinimal = true;
    extraConfig = ''
      CONFIG_LONG_OPTS y
      CONFIG_CHMOD y
      CONFIG_DATE y

      CONFIG_HEAD y
      CONFIG_FEATURE_FANCY_HEAD y

      CONFIG_HEXDUMP y
      CONFIG_MKDIR y
      CONFIG_RM y
      CONFIG_SED y
      CONFIG_TEST1 y
      CONFIG_TR y

      CONFIG_TAR y
      CONFIG_FEATURE_TAR_AUTODETECT y
      CONFIG_FEATURE_SEAMLESS_GZ y
      CONFIG_FEATURE_TAR_LONG_OPTIONS y

      CONFIG_GZIP y
      CONFIG_FEATURE_GZIP_DECOMPRESS y
      CONFIG_XZ y

      SH_IS_ASH y
      CONFIG_ASH y
      CONFIG_FEATURE_SH_MATH y
      CONFIG_ASH_OPTIMIZE_FOR_SIZE y

      CONFIG_FEATURE_UTMP n
      CONFIG_FEATURE_WTMP n
    '';
  };

  nix-shell = ''
    #!/bin/sh
    /bin/statix nix-shell "$@"
  '';
  nix-build = ''
    #!/bin/sh
    /bin/statix nix-build "$@"
  '';
  nix = ''
    #!/bin/sh
    /bin/statix nix "$@"
  '';

  passwd = ''
    root:x:0:0::/root:/run/current-system/sw/bin/bash
    ${concatStringsSep "\n" (genList (i: "nixbld${toString (i+1)}:x:${toString (i+30001)}:30000::/var/empty:/run/current-system/sw/bin/nologin") 32)}
  '';

  group = ''
    root:x:0:
    nogroup:x:65534:
    nixbld:x:30000:${concatStringsSep "," (genList (i: "nixbld${toString (i+1)}") 32)}
  '';

  nixconf = ''
    build-users-group = nixbld
    sandbox = false
  '';

  user-environment = mkDerivation {
    name = "user-environment";
    phases = [
      "installPhase"
    ];

    installPhase = ''
      mkdir -p $out/run/current-system $out/var
      ln -s /run $out/var/run

      mkdir $out/tmp
      mkdir -p $out/bin $out/usr/bin $out/sbin

      cat ${statix}/bin/statix > $out/bin/statix
      chmod 755 $out/bin/statix

      echo '${nix}' > $out/bin/nix
      chmod 755 $out/bin/nix

      echo '${nix-shell}' > $out/bin/nix-shell
      chmod 755 $out/bin/nix-shell

      echo '${nix-build}' > $out/bin/nix-build
      chmod 755 $out/bin/nix-build

      mkdir -p $out/etc/nix
      echo '${nixconf}' > $out/etc/nix/nix.conf
      echo '${passwd}' > $out/etc/passwd
      echo '${group}' > $out/etc/group

      mkdir -p $out/etc/ssl/certs/
    '';
  };

  image = dockerTools.buildImage {
    name = "statix";
    tag = "latest";
    contents = [
      user-environment
      busyboxMinimal
    ];
    config.Env =
      [
        "NIX_PATH=:nixpkgs=https://github.com/NixOS/nixpkgs-channels/archive/3a4ffdd38b56801ce616aa08791121d36769e884.tar.gz"
        "MANPATH=/root/.nix-profile/share/man:/run/current-system/sw/share/man"
        "NIX_PAGER=cat"
    ];
  };
in mkDerivation rec {
    name = "statix";
    src = image;
    installPhase = ''
      mkdir $out
      cp ${image} $out/statix.tgz
      ${gzip}/bin/gunzip $out/statix.tgz
    '';
  }
