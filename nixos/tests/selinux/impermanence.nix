# The impermanence module (nix-community/impermanence): the root is empty
# on every boot and chosen directories and files live on a separate
# filesystem, bind-mounted or linked into place.
#
# Not part of the upstream series: nixpkgs cannot import that module.
{ impermanence }:
{
  name = "selinux-impermanence";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        ./ext4-nix.nix
        "${impermanence}/nixos.nix"
      ];

      security.selinux = {
        enable = true;
        mode = "enforcing";
      };

      virtualisation = {
        memorySize = 2048;
        # An empty filesystem, as the installer would have left it.
        qemu.drives = [
          {
            name = "persist";
            file = "${pkgs.runCommand "selinux-test-persist.img" { nativeBuildInputs = [ pkgs.e2fsprogs ]; } ''
              truncate -s 256M $out
              mkfs.ext4 -q -L persist $out
            ''}";
            driveExtraOpts = {
              format = "raw";
              snapshot = "on";
            };
            deviceExtraOpts.serial = "persist";
          }
        ];
        fileSystems = {
          "/" = lib.mkForce {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [
              "mode=0755"
              "size=1G"
            ];
          };
          "/persist" = {
            device = "/dev/disk/by-label/persist";
            fsType = "ext4";
            neededForBoot = true;
          };
        };
      };

      users.users.alice = {
        isNormalUser = true;
        password = "alice";
      };
      services.openssh.enable = true;

      environment.persistence."/persist" = {
        hideMounts = true;
        directories = [
          "/var/log"
          "/var/lib/nixos"
          "/var/lib/systemd"
        ];
        files = [
          "/etc/machine-id"
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
        ];
        users.alice.directories = [ "documents" ];
      };
    };

  testScript = ''
    def label(path):
        return machine.succeed(f"stat -c %C {path}").strip()

    def check():
        machine.wait_for_unit("multi-user.target")
        assert "tmpfs" in machine.succeed("findmnt -no FSTYPE /")
        assert machine.succeed("getenforce").strip() == "Enforcing"
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        print(machine.succeed("findmnt -o TARGET,SOURCE,FSTYPE | grep -e persist -e '^/ '"))
        print(machine.succeed("ls -Zd /persist /persist/* /persist/var/* /persist/home/* /persist/etc/ssh/* /var/log /etc/machine-id /home/alice /home/alice/documents"))

        # A persisted directory is one inode with two names. It has the
        # type its everyday name calls for.
        assert label("/var/log") == "system_u:object_r:var_log_t:s0", label("/var/log")
        assert label("/persist/var/log") == label("/var/log")
        assert ":user_home_dir_t:" in label("/home/alice"), label("/home/alice")
        assert ":user_home_t:" in label("/home/alice/documents"), label("/home/alice/documents")

        # Nothing was left without a proper type, on either side.
        stray = machine.succeed(
            "getfattr -R -h --absolute-names -n security.selinux /persist /etc /var /root /home 2>/dev/null"
            " | grep -B1 -e ':tmpfs_t:' -e ':unlabeled_t:' -e ':default_t:' -e ':file_t:' || true"
        ).strip()
        assert stray == "", stray
        denials = machine.succeed("journalctl -b --no-pager | grep 'avc:  denied' || true").strip()
        assert denials == "", denials

    machine.start(allow_reboot=True)

    with subtest("first boot: persistent storage is created and labelled"):
        check()
        machine.succeed(
            "echo kept > /home/alice/documents/note",
            "chown alice /home/alice/documents/note",
            "echo lost > /var/lib/lost",
        )
        machine_id = machine.succeed("cat /etc/machine-id")
        host_key = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub")

    with subtest("second boot: the root is empty again, persisted state is back with its labels"):
        machine.reboot()
        check()
        machine.fail("test -e /var/lib/lost")
        assert machine.succeed("cat /home/alice/documents/note").strip() == "kept"
        assert ":user_home_t:" in label("/home/alice/documents/note")
        assert machine.succeed("cat /etc/machine-id") == machine_id
        assert machine.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub") == host_key

    with subtest("a full relabel keeps the persisted files' labels"):
        machine.succeed("nixos-selinux relabel >&2")
        check()
        # Created after the first boot's pass, so only now by its own rule.
        key = label("/persist/etc/ssh/ssh_host_ed25519_key")
        assert ":sshd_key_t:" in key, key

    with subtest("the user can log in over SSH and use the persisted directory"):
        machine.succeed(
            "mkdir -p /root/.ssh && ssh-keygen -q -N ''' -t ed25519 -f /root/.ssh/id_ed25519",
            "install -d -m 700 -o alice /home/alice/.ssh",
            "install -m 600 -o alice /root/.ssh/id_ed25519.pub /home/alice/.ssh/authorized_keys",
            "restorecon -R /home/alice/.ssh",
        )
        out = machine.succeed(
            "ssh -n -o StrictHostKeyChecking=no alice@localhost 'cat documents/note && echo more >> documents/note && id -Z'"
        )
        assert "kept" in out, out
        print(out)
        denials = machine.succeed("journalctl -b --no-pager | grep 'avc:  denied' || true").strip()
        assert denials == "", denials
  '';
}
