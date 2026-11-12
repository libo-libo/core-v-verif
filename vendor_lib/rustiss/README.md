# `rustiss` — Rust RISC-V ISS as the CV32E40P reference model

Replacement for the licensed Imperas `imperas_CV32.dpi.so` in the step-and-compare
flow. Selected with `ISS=RUSTISS`; `ISS ?= IMPERAS` and `imperas_iss.flist` are
untouched, so the Imperas flow is unchanged when a license is available.

```
vendor_lib/rustiss/
  bin/libcv32dpi.so     the DPI model (built elsewhere, installed here)
  sv/rustiss_CV32.sv    `module CPU` implementing the RVVI_step / RVVI_control / RVVI_io / RVVI_bus bundle
```

Wiring: `mk/uvmt/vcs.mk` appends `cv32e40p/tb/uvmt/rustiss_iss.flist` and points
`VCS_OVP_MODEL_DPI` at `bin/libcv32dpi`; `mk/uvmt/uvmt.mk` exports `RUSTISS_HOME`.
The flist is `imperas_iss.flist` minus the OVP design/DPI library, plus
`+incdir+${RUSTISS_HOME}/sv` and this module.

## Model source and build

The model is the `cv32dpi` cdylib target of `rust-iss/` in
[libo-libo/imperas-riscv-tests](https://github.com/libo-libo/imperas-riscv-tests),
branch `v20230724`, commit `02afa92` (no external crates, builds offline):

```bash
git clone -b v20230724 https://github.com/libo-libo/imperas-riscv-tests.git
cd imperas-riscv-tests/rust-iss && cargo build --release
install -m 0755 target/release/libcv32dpi.so <core-v-verif>/vendor_lib/rustiss/bin/
```

`bin/libcv32dpi.so` is committed here so the flow runs without a Rust toolchain;
`source local.sh && rustiss_rebuild` rebuilds it from `RUSTISS_SRC` when the model
changes.

`nm -D --undefined-only bin/libcv32dpi.so` must list exactly six imports:
`svexp_step`, `svexp_dmiWrite`, `svexp_setGPR`, `svexp_setCSR`, `svexp_setDECODE`,
`svexp_setRESULT`.

## DPI boundary

Scalars and `const char *` only. VCS 2023.12 has no `-dpiheader`, so no struct
layout can be validated; all SV↔C arguments are `int`/`longint`/`string`.

* `svimp_entry(cfg, elf, variant)` loads the ELF by **virtual** address, builds the
  machine and parks in a loop of `svexp_step()` / report.
* `svexp_step` waits on `control.notify`, not on `@(posedge bus.Clk)`: the FSM stops
  the clock while the model owns the instruction.
* The SV side never drives `bus`. The model owns memory and mirrors writes into
  `ram.memory.mem` through `svexp_dmiWrite` (word index `address >> 2`), which is
  the array `monitor.sv` dumps a signature from.

## Firmware toolchain requirement

`+firmware=<test>.hex` is produced by `objcopy -O verilog`, which encodes **section
LMAs**. The RISC-V GCC 8.2 bundled in `/opt/riscv32` uses GNU ld 2.32, which emits
`p_paddr != p_vaddr` for this linker script (`.text` VMA `0xc8`, LMA `0x100d4`), so
the hex places `.text` 64 KiB too high and the RTL fetches uninitialised memory from
`0x80` onwards. GNU ld 2.37 emits `paddr == vaddr` for the same script.

The host has two toolchains and each is broken in one way, so both halves are used:
GCC 8.2 from `/opt/riscv32` (soft-float `rv32imc/ilp32` multilibs — the only usable
newlib here) driving the ld 2.37 from `/home/Riscv_Tools`:

```bash
mkdir -p /home/liboeda/libo/opt/rv-ld237
ln -sf /home/Riscv_Tools/bin/riscv32-unknown-elf-ld /home/liboeda/libo/opt/rv-ld237/ld
```

`/home/Riscv_Tools`' own GCC 11.1 cannot be used directly: its `libc.a` and
`libgcc.a` are double-float ABI and every soft-float link fails with
`can't link double-float modules with soft-float modules`.

## Running

The environment is packaged as `local.sh` at the repository root:

```bash
source local.sh
rustiss_case hello-world          # log: /tmp/rustiss-hello-world.log
rustiss_case fibonacci USER_RUN_FLAGS=+rand_stall_obi_disable
rustiss_rebuild                   # after editing rust-iss/src
```

By hand, the same thing (paths shown are this host's — override them with
`CV_LOCAL_TOOLCHAIN`, `CV_LOCAL_LD237`, `CV_LOCAL_VCS_HOME` in `local.sh`):

```bash
cd cv32e40p/sim/uvmt
env -u RISCV_GCC -u SUITEDIR -u IMPERASD_LICENSE_FILE \
  CV_SW_TOOLCHAIN=/opt/riscv32 CV_SW_PREFIX=riscv-none-embed- \
  CV_SW_CFLAGS=-B/home/liboeda/libo/opt/rv-ld237/ \
  V=/home/synopsys/vcs/vcs_vV-2023.12-SP1/vcs/V-2023.12-SP1 \
  bash -c 'export PATH=/opt/riscv32/bin:$V/bin:$PATH VCS_HOME=$V VCS_TARGET_ARCH=linux64; \
    make test TEST=hello-world ISS=RUSTISS VCS_UVMHOME_ARG=$V/etc/uvm'
```

`CV_SW_CFLAGS` reaches both the compile and the link command line
(`mk/Common.mk`), which is how `-B` selects the linker.

Result on this host (`hello-world`, exit status 0):

```
[rustiss] CV32E40P: entry 0x80, misa 0x40001104, 3 segment(s)
Checked PC 10955 times / GPR 350560 times / CSR 120505 times
UVM_ERROR : 0    SIMULATION PASSED with WARNINGS
[rustiss] stepped 10955 instruction(s)
```

## Not modelled

* Interrupts: `irq_i` is not visible across this boundary, so no asynchronous trap is
  ever taken by the model.
* Debug-mode entry, `haltreq`, and external bus errors: same channel, same reason.
* `misa` matches the DUT (`0x4000_1104`: MXL=1, I, M, C); U and S are masked off in
  `dpi.rs::config()`.
* `is_stall_sim` defaults to 1, so the harness skips CSR *wire* checks and
  stable-GPR checks; those comparisons are not exercised by this run.