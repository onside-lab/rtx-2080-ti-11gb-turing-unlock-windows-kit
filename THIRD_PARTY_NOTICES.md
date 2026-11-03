# Third-party notices

## nv-uefi-unlocker

The unlock implementation is by
[physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker),
licensed GPL-2.0-only. This case study used v2.1.6, commit
[`9932cfbe1c2f6ebc0759139a2b0949703c00f82f`](https://github.com/physicsdolphin/nv-uefi-unlocker/tree/9932cfbe1c2f6ebc0759139a2b0949703c00f82f).
Consult that pinned source for its license and build/use requirements. This
kit does not grant rights to upstream code or NVIDIA firmware under MIT.

No upstream source code, compiled EFI, NVIDIA firmware, ROM images, or firmware
payload binaries are included. Users obtain and verify the upstream release
and prepare any required inputs themselves. Local payload manifests describe
those inputs; they do not contain them or authorize redistribution.

[logs/loader-tx-excerpt.log](logs/loader-tx-excerpt.log) is a limited excerpt of
upstream program execution output, retaining original line numbers. Onside Lab
claims no proprietary rights over that output. It is evidence from one run,
not a bundled implementation or proof of the underlying execution mechanism.

## Onside Lab material

The original Windows helpers, benchmark, tests, documentation, and graphics in
this repository are covered by the [MIT License](LICENSE), copyright 2026
Onside Lab. The benchmark is independently written and is not the original
program used to obtain the recorded measurements. Our work does not claim
authorship of the upstream unlock technique.
