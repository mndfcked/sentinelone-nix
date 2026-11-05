{
  pkgs,
  systemdPackage ? pkgs.systemd,
  nativeWrappers ? { },
}:
let
  lib = pkgs.lib;
  architecture =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
      "amd64"
    else
      throw "sentinelone-nix-runtime currently supports x86_64-linux only";

  sources = [
    {
      name = "coreutils";
      bin = "${pkgs.coreutils}/bin";
    }
    {
      name = "passwd";
      bin = "${pkgs.shadow}/bin";
    }
    {
      name = "kmod";
      bin = "${pkgs.kmod}/bin";
    }
    {
      name = "bash";
      bin = "${pkgs.bash}/bin";
    }
    {
      name = "grep";
      bin = "${pkgs.gnugrep}/bin";
    }
    {
      name = "sed";
      bin = "${pkgs.gnused}/bin";
    }
    {
      name = "awk";
      bin = "${pkgs.gawk}/bin";
    }
    {
      name = "which";
      bin = "${pkgs.which}/bin";
    }
    {
      name = "find";
      bin = "${pkgs.findutils}/bin";
    }
    {
      name = "tar";
      bin = "${pkgs.gnutar}/bin";
    }
    {
      name = "gzip";
      bin = "${pkgs.gzip}/bin";
    }
    {
      name = "util-linux";
      bin = "${pkgs.util-linux}/bin";
    }
    {
      name = "procps";
      bin = "${pkgs.procps}/bin";
    }
    {
      name = "systemd";
      bin = "${systemdPackage}/bin";
    }
    {
      name = "binutils";
      bin = "${pkgs.binutils}/bin";
    }
    {
      name = "diffutils";
      bin = "${pkgs.diffutils}/bin";
    }
    {
      name = "glibc-tools";
      bin = "${pkgs.glibc.bin}/bin";
    }
    {
      name = "getent";
      bin = "${pkgs.glibc.getent}/bin";
    }
  ];

  wrapperSources = lib.mapAttrs (_: source: toString source) nativeWrappers;
  systemctlTarget =
    if builtins.hasAttr "systemctl" nativeWrappers then
      "/run/wrappers/bin/systemctl"
    else
      "${systemdPackage}/bin/systemctl";
  adapter = pkgs.replaceVars ./native-systemctl.py {
    python = "${pkgs.python3}/bin/python3";
    realSystemctl = systemctlTarget;
  };
  sourcesFile = pkgs.writeText "sentinelone-nix-runtime-sources.json" (builtins.toJSON sources);
  wrappersFile = pkgs.writeText "sentinelone-nix-runtime-wrappers.json" (
    builtins.toJSON wrapperSources
  );

  runtime =
    pkgs.runCommand "sentinelone-nix-runtime-root"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        mkdir -p "$out/bin" "$out/sources" "$out/native-wrapper-sources"
        ${pkgs.python3}/bin/python3 - "$out" "${sourcesFile}" "${wrappersFile}" "${adapter}" <<'PY'
        import json
        import os
        from pathlib import Path
        import shutil
        import sys

        output = Path(sys.argv[1])
        source_groups = json.loads(Path(sys.argv[2]).read_text())
        wrapper_sources = json.loads(Path(sys.argv[3]).read_text())
        adapter_source = Path(sys.argv[4])

        adapter_path = output / "bin/systemctl"
        shutil.copyfile(adapter_source, adapter_path)
        adapter_path.chmod(0o755)

        exports = {}
        group_counts = {}
        for group in source_groups:
            source_dir = Path(group["bin"])
            if not source_dir.is_dir():
                raise SystemExit("missing native command directory: " + str(source_dir))
            names = []
            source_output = output / "sources" / group["name"]
            source_output.mkdir(parents=True, exist_ok=True)
            for source in sorted(source_dir.iterdir(), key=lambda path: path.name):
                if not source.is_file() or not os.access(source, os.X_OK):
                    continue
                if not str(source).startswith("/nix/store/"):
                    raise SystemExit("native command is not a store path: " + str(source))
                names.append(source.name)
                retained_source = source_output / source.name
                if not os.path.lexists(retained_source):
                    retained_source.symlink_to(str(source))

                if source.name in exports:
                    continue

                wrapper_source = wrapper_sources.get(source.name)
                if wrapper_source is not None:
                    if not wrapper_source.startswith("/nix/store/"):
                        raise SystemExit("native wrapper source is not a store path: " + wrapper_source)
                    retained_wrapper = output / "native-wrapper-sources" / source.name
                    retained_wrapper.symlink_to(wrapper_source)

                if source.name == "systemctl":
                    exports[source.name] = {
                        "path": "/usr/sbin/systemctl",
                        "target": str(adapter_path),
                        "targetKind": "store-target",
                        "source": str(adapter_path),
                    }
                elif wrapper_source is not None:
                    exports[source.name] = {
                        "path": "/usr/sbin/" + source.name,
                        "target": "/run/wrappers/bin/" + source.name,
                        "targetKind": "native-wrapper",
                        "source": wrapper_source,
                    }
                else:
                    exports[source.name] = {
                        "path": "/usr/sbin/" + source.name,
                        "target": str(source),
                        "targetKind": "store-target",
                        "source": str(source),
                    }

            group_counts[group["name"]] = len(names)

        for required_group in ("coreutils", "passwd", "kmod", "bash", "systemd"):
            if group_counts.get(required_group, 0) == 0:
                raise SystemExit("native command group is empty: " + required_group)
        if "systemctl" not in exports:
            raise SystemExit("the systemd source did not provide systemctl")

        exports["/bin/bash"] = {**exports["bash"], "path": "/bin/bash"}
        exports["/usr/lib/systemd/system"] = {
            "path": "/usr/lib/systemd/system",
            "target": "/run/systemd/system",
            "targetKind": "runtime-directory",
            "source": None,
        }
        manifest = {
            "schema": 1,
            "exports": {
                item["path"]: {
                    "target": item["target"],
                    "source": (
                        None if item["targetKind"] == "runtime-directory" else item["source"]
                    ),
                    "native_wrapper": item["targetKind"] == "native-wrapper",
                }
                for item in sorted(exports.values(), key=lambda item: item["path"])
            },
            "required_directories": [
                "/bin",
                "/run/systemd/system",
                "/usr",
                "/usr/sbin",
                "/usr/lib",
                "/usr/lib/systemd",
            ],
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        PY
      '';

  manifest = "${runtime}/manifest.json";

  deb =
    pkgs.runCommand "sentinelone-nix-runtime_1_${architecture}.deb"
      {
        nativeBuildInputs = [
          pkgs.dpkg
          pkgs.python3
        ];
      }
      ''
        mkdir -p "$TMPDIR/package"
        ${pkgs.python3}/bin/python3 - "${manifest}" "$TMPDIR/package" <<'PY'
        import json
        from pathlib import Path
        import sys

        manifest = json.loads(Path(sys.argv[1]).read_text())
        root = Path(sys.argv[2])
        for path, item in manifest["exports"].items():
            destination = root / path.lstrip("/")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(item["target"])

        control = root / "DEBIAN" / "control"
        control.parent.mkdir(parents=True, exist_ok=True)
        control.write_text(
            "Package: sentinelone-nix-runtime\n"
            + "Version: 1\n"
            + "Architecture: amd64\n"
            + "Maintainer: SentinelOne NixOS runtime <noreply@example.invalid>\n"
            + "Provides: coreutils, passwd, kmod\n"
            + "Description: Native runtime tools for the SentinelOne NixOS package\n"
        )
        PY
        # Keep store references in the archive visible to Nix reference scanning.
        dpkg-deb -Znone --build --root-owner-group "$TMPDIR/package" "$out"
      '';
in
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
{
  inherit runtime deb manifest;
}
