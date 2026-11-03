#!/usr/bin/env python3
"""Independent CUDA GEMM microbenchmark. Copyright 2026 Onside Lab; MIT.

Reports arithmetic throughput, not an unlock verdict. No device identifiers
are collected. A separate 64x64 problem checks rounding against CPU float64;
it does not validate every element of the timed matrix product.
"""

import argparse
import json
import math
import statistics
import sys


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def reference_check(torch, dtype, device="cuda"):
    """Compare identical, dtype-rounded inputs with a CPU float64 oracle."""
    generator = torch.Generator(device="cpu").manual_seed(42064)
    left = (torch.randn(64, 64, generator=generator) * 0.125).to(dtype)
    right = (torch.randn(64, 64, generator=generator) * 0.125).to(dtype)
    expected = left.to(torch.float64) @ right.to(torch.float64)
    actual = (left.to(device) @ right.to(device)).to("cpu", torch.float64)
    rtol, atol = (0.005, 0.01) if dtype == torch.float16 else (0.0001, 0.0001)
    passed = bool(torch.isfinite(actual).all()) and torch.allclose(
        actual, expected, rtol=rtol, atol=atol
    )
    return {
        "shape": [64, 64, 64],
        "reference": "CPU-float64",
        "passed": passed,
        "rtol": rtol,
        "atol": atol,
        "max_abs_error": (actual - expected).abs().max().item(),
    }


def measure(torch, dtype, args):
    check = reference_check(torch, dtype)
    if not check["passed"]:
        raise ArithmeticError("reference check failed")
    generator = torch.Generator(device="cuda").manual_seed(42048)
    left = torch.randn(args.size, args.size, device="cuda", dtype=dtype,
                       generator=generator)
    right = torch.randn(args.size, args.size, device="cuda", dtype=dtype,
                        generator=generator)
    output = torch.empty_like(left)
    for _ in range(args.warmup):
        torch.mm(left, right, out=output)
    torch.cuda.synchronize()
    durations = []
    start = torch.cuda.Event(enable_timing=True)
    finish = torch.cuda.Event(enable_timing=True)
    for _ in range(args.samples):
        start.record()
        for _ in range(args.iterations):
            torch.mm(left, right, out=output)
        finish.record()
        finish.synchronize()
        seconds = start.elapsed_time(finish) / (1000 * args.iterations)
        if not math.isfinite(seconds) or seconds <= 0:
            raise ArithmeticError("invalid event duration")
        durations.append(seconds)
    rates = [2 * args.size ** 3 / seconds / 1e12 for seconds in durations]
    return {
        "workload": "FP16-input-GEMM" if dtype == torch.float16 else "FP32-SIMT",
        "seconds_per_product": durations,
        "tflops": rates,
        "median_tflops": statistics.median(rates),
        "numerical_check": check,
    }


def main():
    parser = argparse.ArgumentParser(
        prog="gemm_bench.py", description="CUDA FP16-input and strict FP32 GEMM"
    )
    parser.add_argument("--size", type=positive_integer, default=2048)
    parser.add_argument("--samples", type=positive_integer, default=5)
    parser.add_argument("--iterations", type=positive_integer, default=20)
    parser.add_argument("--warmup", type=positive_integer, default=10)
    args = parser.parse_args()
    try:
        import torch
    except ImportError:
        print('{"error": "PyTorch is required"}', file=sys.stderr)
        return 2
    try:
        if not torch.cuda.is_available():
            print('{"error": "CUDA is required"}', file=sys.stderr)
            return 2
        torch.set_float32_matmul_precision("highest")
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
        torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False
        accumulation_control = hasattr(
            torch.backends.cuda.matmul, "allow_fp16_accumulation"
        )
        if accumulation_control:
            torch.backends.cuda.matmul.allow_fp16_accumulation = False
        with torch.inference_mode():
            results = [measure(torch, dtype, args)
                       for dtype in (torch.float16, torch.float32)]
        report = {
            "torch_version": torch.__version__,
            "size": args.size,
            "samples": args.samples,
            "iterations_per_sample": args.iterations,
            "warmup_iterations": args.warmup,
            "tf32_allowed": False,
            "fp16_reduced_precision_reduction": False,
            "fp16_accumulation_control_available": accumulation_control,
            "kernel_accumulation_mode_independently_instrumented": False,
            "results": results,
            "limitations": [
                "Short microbenchmark; not an endurance or application test",
                "The 64x64 reference check is separate from the timed product",
                "Backend flags do not independently prove kernel accumulation type",
            ],
        }
        print(json.dumps(report, indent=2, allow_nan=False))
        return 0
    except Exception:
        # Suppress exception text and tracebacks that may contain local paths.
        print('{"error": "Benchmark or numerical check failed"}', file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
