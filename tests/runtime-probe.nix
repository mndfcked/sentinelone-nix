{ pkgs }:
let
  fallbackLibraries =
    pkgs.runCommand "sentinelone-runtime-fallback-libraries"
      {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
        NIX_NO_SELF_RPATH = "1";
      }
      ''
        mkdir -p "$out/lib"
        $CC -shared -fPIC ${./fixtures/host-dependency.c} \
          -Wl,-soname,libhostdep.so -o "$out/lib/libhostdep.so"
        $CC -shared -fPIC ${./fixtures/vendor-fallback.c} \
          -Wl,-soname,libvendor.so -o "$out/lib/libvendor.so"
      '';

  fixtures =
    pkgs.runCommand "sentinelone-runtime-probe-fixtures"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.binutils
        ];
        # Suppress the wrapper's default $out/lib rpath; fixture search paths are explicit.
        NIX_NO_SELF_RPATH = "1";
      }
      ''
        mkdir -p "$TMPDIR/linklib" "$TMPDIR/soname" "$out/bin" "$out/lib"

        # Compile private libraries in the build directory. Only vendor and transitive
        # libraries are bundled; libhostdep is available solely from the loader fallback.
        $CC -shared -fPIC ${./fixtures/host-dependency.c} \
          -Wl,-soname,libhostdep.so -o "$TMPDIR/linklib/libhostdep.so"
        $CC -shared -fPIC ${./fixtures/vendor.c} \
          -Wl,-soname,libvendor.so -o "$TMPDIR/linklib/libvendor.so"
        $CC -shared -fPIC ${./fixtures/transitive.c} \
          -Wl,-soname,libtransitive.so -o "$TMPDIR/linklib/libtransitive.so"
        $CC -shared -fPIC ${./fixtures/probe-library.c} -L"$TMPDIR/linklib" \
          -lhostdep -lvendor -ltransitive -Wl,-soname,libfixture.so \
          -Wl,-rpath,'$ORIGIN' -o "$TMPDIR/linklib/libfixture.so"

        cp "$TMPDIR/linklib/libvendor.so" "$out/lib/libvendor.so"
        cp "$TMPDIR/linklib/libtransitive.so" "$out/lib/libtransitive.so"
        cp "$TMPDIR/linklib/libfixture.so" "$out/lib/libfixture.so"

        $CC -DPROBE_VERSION='"A"' ${./fixtures/probe.c} -L"$TMPDIR/linklib" -lfixture \
          -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 \
          -Wl,-rpath,'$ORIGIN/../lib' -o "$out/bin/runtime-probe-a"
        $CC -DPROBE_VERSION='"B"' ${./fixtures/probe.c} -L"$TMPDIR/linklib" -lfixture \
          -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 \
          -Wl,-rpath,'$ORIGIN/../lib' -o "$out/bin/runtime-probe-b"
        $CC ${./fixtures/distro-child.c} -L"$TMPDIR/linklib" -lfixture \
          -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 \
          -Wl,-rpath,'$ORIGIN/../lib' -o "$out/bin/distro-child"
        $CC ${./fixtures/sentinelctl.c} -L"$TMPDIR/linklib" -lfixture \
          -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 \
          -Wl,-rpath,'$ORIGIN/../lib' -o "$out/bin/sentinelctl-fixture"

        # Deliberately mismatch the file name and SONAME. No versioned alias is created.
        $CC -shared -fPIC ${./fixtures/soname-library.c} \
          -Wl,-soname,librequired.so.9 -o "$TMPDIR/soname/librequired.so"
        cp "$TMPDIR/soname/librequired.so" "$out/lib/librequired.so"
        $CC ${./fixtures/soname-negative.c} -L"$TMPDIR/soname" -l:librequired.so \
          -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 \
          -Wl,-rpath,'$ORIGIN/../lib' -o "$out/bin/soname-negative"

        assert_distro_elf() {
          binary="$1"
          ${pkgs.binutils}/bin/readelf -lW "$binary" | \
            grep -F '[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]'
          dynamic="$(${pkgs.binutils}/bin/readelf -dW "$binary")"
          printf '%s\n' "$dynamic" | grep -F 'Library runpath: [$ORIGIN/../lib'
          if printf '%s\n' "$dynamic" | grep -F "$out"; then
            echo "$binary embeds its Nix-store output path in a library search path" >&2
            return 1
          fi
        }

        for binary in runtime-probe-a runtime-probe-b distro-child sentinelctl-fixture soname-negative; do
          assert_distro_elf "$out/bin/$binary"
        done

        fixture_dynamic="$(${pkgs.binutils}/bin/readelf -dW "$out/lib/libfixture.so")"
        printf '%s\n' "$fixture_dynamic" | grep -F 'Library runpath: [$ORIGIN'
        for library in libhostdep.so libtransitive.so libvendor.so; do
          printf '%s\n' "$fixture_dynamic" | grep -F "Shared library: [$library]"
        done
        if printf '%s\n' "$fixture_dynamic" | grep -F "$out"; then
          echo "libfixture embeds its Nix-store output path in a library search path" >&2
          exit 1
        fi

        ${pkgs.binutils}/bin/readelf -dW "$out/bin/soname-negative" | \
          grep -F 'Shared library: [librequired.so.9]'
        test -e "$out/lib/librequired.so"
        test ! -e "$out/lib/librequired.so.9"
        test ! -e "$out/lib/libhostdep.so"
      '';

  loaderEnvironment = {
    NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
    NIX_LD_LIBRARY_PATH = "/opt/sentinelone/lib:${fallbackLibraries}/lib:/run/current-system/sw/share/nix-ld/lib";
  };
  loaderEnvAssignments = "NIX_LD=${loaderEnvironment.NIX_LD} NIX_LD_LIBRARY_PATH=${loaderEnvironment.NIX_LD_LIBRARY_PATH}";
in
pkgs.testers.nixosTest {
  name = "sentinelone-vendor-runtime";

  nodes.machine = { ... }: {
    programs.nix-ld = {
      enable = true;
      libraries = [ fallbackLibraries ];
    };

    systemd.services.vendor-runtime-probe = {
      description = "Synthetic vendor-runtime prerequisite probe";
      environment = loaderEnvironment;
      serviceConfig = {
        Type = "exec";
        ExecStart = "/opt/sentinelone/bin/runtime-probe service";
      };
    };

    systemd.services.vendor-runtime-admin = {
      description = "Synthetic vendor-runtime administrative probe";
      environment = loaderEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/opt/sentinelone/bin/sentinelctl-fixture";
      };
    };
  };

  testScript = ''
    machine.start(allow_reboot=True)

    # Synthetic test fixture setup only; this does not exercise a production initializer or updater.
    machine.succeed("install -d -o root -g root -m 0755 /opt/sentinelone /opt/sentinelone/bin /opt/sentinelone/lib")
    machine.succeed("install -o root -g root -m 0755 ${fixtures}/bin/runtime-probe-a /opt/sentinelone/bin/runtime-probe")
    machine.succeed("install -o root -g root -m 0755 ${fixtures}/bin/distro-child ${fixtures}/bin/sentinelctl-fixture ${fixtures}/bin/soname-negative /opt/sentinelone/bin/")
    machine.succeed("install -o root -g root -m 0644 ${fixtures}/lib/libfixture.so ${fixtures}/lib/libvendor.so ${fixtures}/lib/libtransitive.so ${fixtures}/lib/librequired.so /opt/sentinelone/lib/")
    machine.succeed("test \"$(stat -c '%U:%G:%a' /opt/sentinelone)\" = root:root:755")
    machine.succeed("test \"$(stat -c '%U:%G:%a' /opt/sentinelone/bin/runtime-probe)\" = root:root:755")
    machine.succeed("touch /opt/sentinelone/lib/.root-write-test && rm /opt/sentinelone/lib/.root-write-test")
    machine.succeed("test -e ${fallbackLibraries}/lib/libvendor.so")

    machine.succeed("systemctl start vendor-runtime-probe.service")
    machine.wait_for_unit("vendor-runtime-probe.service")
    machine.wait_until_succeeds("journalctl -b -u vendor-runtime-probe.service --no-pager | grep -F 'RUNTIME_VERSION=A VALUE=45'")
    machine.wait_until_succeeds("journalctl -b -u vendor-runtime-probe.service --no-pager | grep -F 'DISTRO_CHILD_VALUE=45'")

    machine.succeed(r"""
      service_pid="$(systemctl show -P MainPID vendor-runtime-probe.service)"
      child_pid="$(cat /run/sentinelone-runtime-child.pid)"
      for namespace in pid mnt; do
        init_namespace="$(readlink "/proc/1/ns/$namespace")"
        test "$(readlink "/proc/$service_pid/ns/$namespace")" = "$init_namespace"
        test "$(readlink "/proc/$child_pid/ns/$namespace")" = "$init_namespace"
      done
    """)

    probe_output = machine.succeed("env ${loaderEnvAssignments} /opt/sentinelone/bin/runtime-probe")
    if "FIXTURE_VALUE=45" not in probe_output:
        raise Exception("vendor and transitive library return values were not 45: " + probe_output)

    child_output = machine.succeed("env ${loaderEnvAssignments} /opt/sentinelone/bin/runtime-probe child")
    if "DISTRO_CHILD_VALUE=45" not in child_output:
        raise Exception("the distro-style child did not run with the expected value: " + child_output)

    nix_child_output = machine.succeed("env ${loaderEnvAssignments} /opt/sentinelone/bin/runtime-probe exec ${pkgs.coreutils}/bin/printf TRUSTED_NIX_CHILD_OK")
    if "TRUSTED_NIX_CHILD_OK" not in nix_child_output:
        raise Exception("the trusted Nix-packaged child did not execute: " + nix_child_output)

    cleared_nix_child = machine.succeed("env -u NIX_LD -u NIX_LD_LIBRARY_PATH ${pkgs.coreutils}/bin/printf TRUSTED_NIX_CHILD_WITHOUT_NIX_LD")
    if "TRUSTED_NIX_CHILD_WITHOUT_NIX_LD" not in cleared_nix_child:
        raise Exception("the Nix-packaged child did not report its env-cleared behavior: " + cleared_nix_child)

    cleared_distro_child = machine.succeed("set +e; env -u NIX_LD -u NIX_LD_LIBRARY_PATH /opt/sentinelone/bin/distro-child > /tmp/env-cleared-distro-child.log 2>&1; status=$?; cat /tmp/env-cleared-distro-child.log; test $status -eq 1")
    if "DISTRO_CHILD_VALUE=941" not in cleared_distro_child:
        raise Exception("env-cleared distro ELF did not expose fallback-library precedence: " + cleared_distro_child)

    machine.succeed("test -e /opt/sentinelone/lib/librequired.so && test ! -e /opt/sentinelone/lib/librequired.so.9")
    soname_failure = machine.succeed("set +e; env ${loaderEnvAssignments} /opt/sentinelone/bin/soname-negative > /tmp/soname-negative.log 2>&1; status=$?; cat /tmp/soname-negative.log; test $status -ne 0")
    if "librequired.so.9" not in soname_failure:
        raise Exception("the missing SONAME filename was not reported: " + soname_failure)

    # This copy simulates replacement of a synthetic file only; it is not an updater contract.
    machine.succeed("install -o root -g root -m 0755 ${fixtures}/bin/runtime-probe-b /opt/sentinelone/bin/runtime-probe")
    machine.succeed("cmp ${fixtures}/bin/runtime-probe-b /opt/sentinelone/bin/runtime-probe")
    machine.succeed("systemctl restart vendor-runtime-probe.service")
    machine.wait_for_unit("vendor-runtime-probe.service")
    machine.wait_until_succeeds("journalctl -b -u vendor-runtime-probe.service --no-pager | grep -F 'RUNTIME_VERSION=B VALUE=45'")

    machine.succeed("systemctl stop vendor-runtime-probe.service")
    machine.succeed("systemctl start vendor-runtime-admin.service")
    machine.wait_until_succeeds("journalctl -b -u vendor-runtime-admin.service --no-pager | grep -F 'ADMIN_VALUE=45'")

    machine.reboot()
    machine.succeed("cmp ${fixtures}/bin/runtime-probe-b /opt/sentinelone/bin/runtime-probe")
    machine.succeed("systemctl start vendor-runtime-probe.service")
    machine.wait_for_unit("vendor-runtime-probe.service")
    machine.wait_until_succeeds("journalctl -b -u vendor-runtime-probe.service --no-pager | grep -F 'RUNTIME_VERSION=B VALUE=45'")
  '';
}
