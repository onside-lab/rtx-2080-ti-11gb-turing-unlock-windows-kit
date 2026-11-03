# RTX 2080 Ti (TU102) Pre-OS Unlock Field Report

As an Onside technical case study, we ran a single pre-OS unlock on an NVIDIA GeForce RTX 2080 Ti (TU102) we had on hand using upstream `nv-uefi-unlocker`, and measured matrix multiplication before and after the unlock. Median FP16-input GEMM rose from 46.88 to 87.17 TFLOPS (~1.86×), while FP32 SIMT changed from 12.61 to 12.27 TFLOPS. These numbers are from a short microbenchmark and do not show that end-to-end local LLM or image generation workloads will speed up by the same factor.

Author: Onside Lab

## Results

| Metric | Before unlock | After unlock | After / Before |
| --- | ---: | ---: | ---: |
| FP16-input GEMM (TFLOPS) | 46.88 | 87.17 | 1.86 |
| FP32 SIMT (TFLOPS) | 12.61 | 12.27 | 0.97 |
| Numerical verification against 64×64 CPU float64 reference | Passed | Passed | — |
| Power limit (W) | 192.5 | 192.5 | — |
| Representative SM clock (MHz) | 1590 | 1575 | — |

![Comparison of FP16-input GEMM and FP32 SIMT before and after unlock](results/chart.png)

Matrix size was 2048×2048. After 10 warmup runs, 20 matrix products were measured as one sample across 5 samples, and median TFLOPS values were compared. Computational complexity is defined as `2 × N³` per product. Only the table and chart are rounded; [benchmark.json](results/benchmark.json) retains the unrounded median values. The power limit is not actual power consumption. Clocks were not locked; observations in the original samples include 1350 MHz before unlock and 1635 MHz after unlock.

Tests ran on PyTorch 2.5.1+cu121, with TF32 and FP16 reduced-precision reduction disabled. FP16 denotes the **input data type**. Because accumulation precision of the actual kernel was not independently measured, we do not claim this as FP32-accumulation performance. The numerical verification checked a separate 64×64 problem, not every element of the 2048×2048 matrices. Furthermore, based on only two measurement sets, neither the cause nor the statistical significance of the slight FP32 decrease can be determined.

## Environment

| Item | Value |
| --- | --- |
| GPU | NVIDIA GeForce RTX 2080 Ti (TU102) |
| PCI ID | `10de:1e04` |
| Subsystem ID | `1043:8675` |
| VBIOS | `90.02.17.00.b2` |
| OS | Windows 11 |
| NVIDIA driver | `610.88` |
| Driver operating mode | GSP-RM mode (GSP firmware `610.57.01`) |
| PyTorch | `2.5.1+cu121` |
| Power limit | 192.5 W (identical before and after) |
| Upstream pinned release | v2.1.6 |
| Upstream commit | [`9932cfbe1c2f6ebc0759139a2b0949703c00f82f`](https://github.com/physicsdolphin/nv-uefi-unlocker/tree/9932cfbe1c2f6ebc0759139a2b0949703c00f82f) |

## Procedure overview

This repository does not distribute binary executables or provide an automated unlock mechanism. The procedure performed on the physical machine was as follows:

| Phase | Gate to proceed | Abort and rollback procedure |
| --- | --- | --- |
| Diagnosis | Match GPU identity against the pinned version; verify read-only diagnostics and pre-unlock measurements | If any mismatch or abnormality appears in diagnostics, do not proceed to unlock; return to normal Windows boot |
| GSP mode | Record settings before changes, enable GSP mode, reboot, and verify configured values and actual GSP firmware operation | If any abnormality occurs, do not proceed to unlock; restore recorded settings and reboot |
| Single unlock boot | Verify pinned binaries and assets, enter via temporary boot menu, and run exactly once through the confirmation screen | Abort before confirmation if needed. If a STOP or abnormality occurs during execution, do not re-run in the same session; power down completely, unplug the unlock media, and boot normally |
| After returning to Windows | Verify Turing selector values in the log, plus measurements and numerical verification under identical conditions | If display or driver anomalies or verification failures occur, stop operation; power down completely, then boot normally without the unlock |

Because GSP configuration changes persist independently of the unlock state, that configuration must also be restored when reverting to the original environment. The unlock itself is volatile and must be reapplied for each boot where it is used. Having recovery procedures prepared does not guarantee recovery. Prerequisites and recovery steps are described in the upstream [pinned release README](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/9932cfbe1c2f6ebc0759139a2b0949703c00f82f/README.md).

The [loader excerpt](logs/loader-tx-excerpt.log) preserves original line numbers. In SAMPLE, Turing FEAT_PLM=`0xffffff8f` and SS0=`0x00002100` are recorded; FWSEC passed WPR2 verification; in POST-BOOT, FEAT_PLM=`0xffffffff` is recorded, followed by SS0=`0x88888888` / SS1=`0x8`. The Turing selector values also persist across relock and final handoff, reporting `tu10x_unlock=true`. Meanwhile, BOOTER-DIRECT diagnostics record `signature DMA never landed`. The excerpt retains both records, and log text alone is not treated as proof of the underlying execution mechanism.

## What remains untested

- Only one card was tested in a single unlock run. Reproducibility across multiple boots, as well as behavior on other hardware units, VBIOS versions, or driver versions, remains untested.
- Sustained long-duration workloads, sleep/hibernate resume, and gaming behavior remain untested.
- Local LLM tokens/s, image generation duration, and production stability or cost-effectiveness were not measured.
- No independent readback of FEAT registers was performed within Windows. EFI-side logs and Windows-side performance changes are treated distinctly.
- Persistence and automated unlock on every boot were not tested. The unlock is volatile, not a permanent performance modification.

## Contents and credits

- [Onside case study](docs/case-study.md)
- [Benchmark summary](results/benchmark.json)
- [Limited loader log excerpt](logs/loader-tx-excerpt.log)
- [Independently written generic GEMM benchmark script](bench/gemm_bench.py)

The unlock implementation is by [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker). The contribution of this repository is the record of physical verification using the pinned release, along with our independently written benchmark script. We make no claim of having developed the unlock technique itself.

Upstream source code, NVIDIA firmware, and built EFI binaries are not included. Upstream is licensed under GPL-2.0-only, and NVIDIA firmware is treated as non-distributable; neither is redistributed here. Original writing and scripts are under the [MIT License](LICENSE). The log is a limited excerpt of the upstream program's execution output, and no proprietary rights are claimed over that text.

The bundled benchmark script is not a copy of the original measurement program. It can be run with `python bench/gemm_bench.py` after preparing a PyTorch and CUDA-capable environment. While it includes warmup runs, median calculation, and small-matrix verification, it is not the exact program that generated the recorded measurements and does not guarantee reproduction of the same numbers. It does not output system identifiers or device listings; it prints benchmark results as JSON to stdout.

## Disclaimer and support

Execution and use are at your own risk. Operation, performance, and recovery are not guaranteed in any way. This repository is a record of a case study. We provide no support for individual environments and do not accept questions, GitHub Issues, or pull requests. This repository is read-only.
