# Search: the engine, the download and your limits

Hrafn, drgnx's code and docs search, makes its vectors on your GPU with a llama.cpp engine it runs itself. It never
indexes on the CPU unless you say so.

## The download and its total

`ratatoskr search download qwen3-embedding-0.6b-q8_0` lists every file it would fetch, each with its bytes, the total
and the exact command to run. Run that command (`--consent-bytes N`) to consent and start the download. A wrong number
is refused with the right command.

The model is 639,150,592 bytes. The engine is the build for your GPU, and the total is the sum:

| Your GPU | Engine build | Total download (bytes) |
|---|---|---|
| NVIDIA, Linux x64, driver 580 or newer | CUDA 13.5 (plus its runtime libraries) | 1,252,982,236 |
| NVIDIA, Linux x64, driver 570 to 579 | CUDA 12.8 (plus its runtime libraries) | 1,421,666,499 |
| NVIDIA, Linux arm64, driver 580 or newer | CUDA 13.5 (plus its runtime libraries) | 1,363,796,812 |
| AMD, Linux x64, with ROCm 7.x installed | ROCm | 894,679,652 |
| Apple silicon | Metal | 655,859,017 |
| Intel, and any GPU the vendor build cannot drive, Linux x64 | Vulkan | 675,033,530 |
| The same, Linux arm64 | Vulkan | 668,343,524 |

`ratatoskr doctor` names the build chosen for your machine and why a vendor build was not used (an old driver, no
`/dev/kfd`, an AMD card outside ROCm's list).

## What the vendor runtimes need

- **NVIDIA:** a driver new enough for the build (580 for CUDA 13.5, 570 for CUDA 12.8). The CUDA libraries come in the download.
- **AMD:** the ROCm 7.x libraries from your distribution (`rocm-hip`, `hipblas`, `rocblas`, `rocsolver`,
  `rocm-runtime`) or AMD's ROCm install; upstream's build bundles none. You must be in the `render` and `video` groups.
  `doctor` names each library that is missing.
- **Intel and the fallbacks:** a Vulkan driver.

## Which GPUs

By default the fastest GPU runs. When more usable GPUs exist, `doctor` lists them. `drgnx-search-gpus` sets which run:
`"all"`, `"top:2"` or `"ids:CUDA0,CUDA1"`. Each runs its own engine on its own device, and batches go to each by its
measured speed. `CUDA_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES` and `HIP_VISIBLE_DEVICES` are respected.

## No GPU, and battery

A machine with no usable GPU waits for your choice (`drgnx-search-no-gpu`): `"pack"` (vectors from a pack or a remote
GPU), `"cpu"` (indexing on the CPU within your CPU limit) or `"cpu-idle"` (on the CPU only while the machine is idle).
On battery, `drgnx-search-battery-gpu` is `"pause"` (the default), `"igpu"` or `"dgpu"`.

## Limits

Each is enforced; hitting one slows indexing and never fails it silently.

| Setting | Limit |
|---|---|
| `drgnx-search-cpu-limit` | percent of the machine's CPUs: the engine's threads and `cpu.max` |
| `drgnx-search-memory-limit` | MiB of RAM: `memory.max` |
| `drgnx-search-vram-limit` | MiB of video memory: the engine is sized to it and refused when it would pass |
| `drgnx-search-gpu-busy` | percent the GPU may be busy: batches are paced |

## A game or a job on the GPU

While another program works on the engine's GPU, indexing waits after the batch it is on and goes on when the program
stops. `ratatoskr search status` names the program (`held`, with the reason). Two things count: a process other than
our own engines that uses at least 10 percent of the GPU (NVIDIA: `nvidia-smi pmon`; AMD and Intel: the DRM client list in
`/proc`), and free video memory under what the engine needs. A program that only holds a context open and does nothing
(a compositor) does not hold the GPU.

The CPU and memory limits are held by a systemd user scope where your user manager runs; without one, `doctor` says the
limit rests on the engine's thread count alone.
