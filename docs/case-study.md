# Onside Technical Case Study: Measuring Compute Performance Changes on an RTX 2080 Ti

Author: Onside Lab

## Objective

We wanted to speed up local LLMs and image generation on an existing GPU. Before considering purchasing additional hardware, we verified on physical hardware whether compute performance could change on our current RTX 2080 Ti (TU102). As an Onside technical case study, this document records the conditions tested and the scope observed.

## Approach

We used [nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker) for the unlock implementation. Pinning to v2.1.6, commit `9932cfbe1c2f6ebc0759139a2b0949703c00f82f`, we proceeded in stages: diagnostics, switching to GSP mode and rebooting, a single unlock boot, and measurements after returning to Windows. The unlock mechanism was developed by the upstream project; our contribution was to verify it on physical hardware under fixed conditions.

At each stage, we prepared verification gates before proceeding, along with rollback procedures. If diagnostic criteria were not met, we did not advance. If we could not confirm GSP operation, we would restore the original configuration. If an abnormality occurred during the unlock process, we avoided repeating it in the same session, powered down completely, and returned to a normal boot. After returning to Windows, our policy was to verify both numerical correctness and speed.

## Results

For a single unlock run on one card, we measured 5 samples of 20 matrix products with matrix size 2048. PyTorch was 2.5.1+cu121, and the power limit was 192.5 W before and after.

| Metric | Before unlock | After unlock |
| --- | ---: | ---: |
| Median FP16-input GEMM (TFLOPS) | 46.88 | 87.17 |
| Median FP32 SIMT (TFLOPS) | 12.61 | 12.27 |
| Numerical verification against 64×64 CPU float64 reference | Passed | Passed |

FP16-input GEMM showed a ~1.86× change. FP32 showed no comparable increase. The representative SM clock was 1590 → 1575 MHz, but this was not a locked-clock comparison because clocks fluctuated during measurement. Original median values and measurement conditions are in [benchmark.json](../results/benchmark.json); procedures and environment details are in the [README](../README.md).

## Limitations

This measurement reflects short-duration matrix multiplication. While FP16 input was confirmed, kernel accumulation precision was not independently measured. The numerical verification evaluated a separate 64×64 problem, not every element of the large matrices benchmarked for performance.

This study did not measure local LLM response latency or image generation time, and does not claim they will speed up by 1.86×. Long-term stability, sleep/resume, gaming, other hardware units, and reproducibility across multiple boots remain untested. The unlock is volatile and must be reapplied for every boot where it is needed. Reverting to stock requires booting normally after a complete power-off without running the unlock, as well as restoring the separately modified GSP configuration. Recovery is not guaranteed.

## Considerations for small businesses using existing GPUs

Matrix multiplication performance is only one factor when evaluating existing hardware. For deployment decisions in production, teams must verify on actual target workloads whether the model fits into GPU memory, runs at the required quality, and genuinely reduces wait times. The TFLOPS figures in this case study alone cannot determine whether purchasing additional GPUs can be avoided or whether overall deployment costs can be reduced.

Comparisons against hardware purchases must account not only for raw performance, but also for the per-boot operational overhead, recovery time during anomalies, and long-term maintainability. We present these findings as a single example where compute performance of an existing GPU was unlocked conditionally; adoption in production environments should be decided based on actual workloads and operational conditions.

Execution and use are at your own risk, with no warranty. We provide no support for individual environments and do not accept questions, GitHub Issues, or pull requests.
