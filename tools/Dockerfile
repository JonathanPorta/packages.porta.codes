# The pinned toolchain for admission, generation and verification
# (blessed releases.package-repositories@1 PR-4: pinned metadata generators).
# The base is pinned by digest; the generators by exact version, and
# pkgrepo-generate.sh refuses any version other than tools/tool-pins — so a
# silent toolchain change fails loudly instead of producing a different
# generation. Bump the digest, the versions below and tools/tool-pins together.
FROM docker.io/library/fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80
RUN dnf -y install --setopt=install_weak_deps=False \
      dpkg-1.23.7 createrepo_c-1.2.1 rpm gnupg2 jq curl openssl findutils diffutils gzip \
    && dnf clean all
