# A single-node k3s cluster on an SELinux system: the host's services are
# confined, k3s and its pods are not, and a pod runs.
#
# With `enforcing = false` the same script runs in permissive mode and
# only prints the denials.
{
  enforcing ? true,
}:
{
  name = if enforcing then "selinux-k3s" else "selinux-k3s-audit";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      pauseImage = pkgs.dockerTools.buildLayeredImage {
        name = "test.local/pause";
        tag = "local";
        contents = pkgs.buildEnv {
          name = "pause-image-env";
          paths = [
            pkgs.tini
            (lib.hiPrio pkgs.coreutils)
            pkgs.busybox
          ];
        };
        config.Entrypoint = [
          "/bin/tini"
          "--"
          "/bin/sleep"
          "inf"
        ];
      };
    in
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        mode = if enforcing then "enforcing" else "permissive";
        logAllDenials = !enforcing;
      };

      services.k3s = {
        enable = true;
        role = "server";
        disable = [
          "coredns"
          "local-storage"
          "metrics-server"
          "servicelb"
          "traefik"
        ];
        images = [ pauseImage ];
        extraFlags = [ "--pause-image test.local/pause:local" ];
      };

      environment = {
        systemPackages = [ pkgs.kubectl ];
        sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        etc."selinux-test/pod.yaml".text = ''
          apiVersion: v1
          kind: Pod
          metadata:
            name: test
          spec:
            containers:
            - name: test
              image: test.local/pause:local
              imagePullPolicy: Never
              command: ["sh", "-c", "sleep inf"]
        '';
      };

      virtualisation = {
        memorySize = 3072;
        cores = 2;
        diskSize = 4096;
      };
    };

  testScript = ''
    strict = ${if enforcing then "True" else "False"}

    def denials():
        summary = machine.succeed(
            "journalctl -b --no-pager -o cat | grep 'avc:  denied'"
            " | sed -E 's/.*denied  (\\{[^}]*\\}).*comm=\"([^\"]*)\".*scontext=([^ ]+) tcontext=([^ ]+) tclass=([^ ]+).*/\\3 \\4 \\5 \\1 \\2/'"
            " | sort | uniq -c | sort -rn | head -150 || true"
        ).strip()
        print(summary)
        return summary if strict else ""

    def pod_runs():
        machine.wait_for_unit("k3s.service")
        machine.wait_until_succeeds("kubectl get serviceaccount default", timeout=300)
        machine.succeed("kubectl apply -f /etc/selinux-test/pod.yaml")
        machine.succeed("kubectl wait --for condition=Ready pod/test --timeout=300s")
        assert machine.succeed("kubectl exec test -- echo hello").strip() == "hello"
        machine.succeed("kubectl logs test >&2")

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    with subtest("the system is in the expected mode"):
        assert machine.succeed("getenforce").strip() == ("Enforcing" if strict else "Permissive")
        print(machine.succeed("nixos-selinux status"))

    with subtest("k3s starts and runs a pod"):
        pod_runs()
        print(machine.succeed("ps -eo label,comm | grep -E 'k3s|containerd|sleep|tini' | sort | uniq -c"))

    with subtest("nothing was denied"):
        assert denials() == ""
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    with subtest("the cluster comes back after a reboot"):
        machine.succeed("kubectl delete -f /etc/selinux-test/pod.yaml --wait=true --timeout=120s")
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        pod_runs()
        assert denials() == ""
  '';
}
