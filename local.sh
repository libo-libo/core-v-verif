#!/bin/bash
# Environment for running cv32e40p UVM tests with the Rust ISS as reference model.
#
#   source local.sh
#   rustiss_case hello-world
#   rustiss_case fibonacci USER_RUN_FLAGS=+rand_stall_obi_disable
#
# Sourced, never executed: it only sets variables and defines one helper, so it
# cannot abort your shell. Safe to source twice (no duplicate PATH entries).

_CV_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_CV_SIM_UVMT=$_CV_ROOT/cv32e40p/sim/uvmt

# --- toolchain -------------------------------------------------------------
# Firmware GCC: soft-float rv32imc/ilp32 multilibs. Required — the other
# toolchain on this host (/home/Riscv_Tools, GCC 11.1) ships double-float
# libc.a/libgcc.a, so every soft-float link fails with
# "can't link double-float modules with soft-float modules".
#
# The ambient CV_SW_TOOLCHAIN must not win here: this host's profile points it
# at the SiFive RVV toolchain, whose multilibs are also double-float. Override
# with CV_LOCAL_TOOLCHAIN, not with CV_SW_TOOLCHAIN.
export CV_SW_TOOLCHAIN=${CV_LOCAL_TOOLCHAIN:-/opt/riscv32}
export CV_SW_PREFIX=${CV_LOCAL_PREFIX:-riscv-none-embed-}

# Linker: GNU ld 2.37, reached through the GCC 8.2 driver with -B. Required —
# the ld 2.32 that ships with /opt/riscv32 emits p_paddr != p_vaddr for
# cv32e40p/bsp/link.ld; `objcopy -O verilog` encodes LMAs, so the resulting
# .hex loads .text 64 KiB above its virtual address and the RTL fetches
# uninitialised memory (Illegal instruction at 0x690, PC=0x00000000 compares).
_CV_LD237=${CV_LOCAL_LD237:-/home/liboeda/libo/opt/rv-ld237}
export CV_SW_CFLAGS=${CV_LOCAL_CFLAGS:--B$_CV_LD237/}

# --- simulator -------------------------------------------------------------
# Same reason: the ambient VCS_HOME here is VCS O-2018.09-SP2, which cannot
# elaborate this TB. Override with CV_LOCAL_VCS_HOME.
export VCS_HOME=${CV_LOCAL_VCS_HOME:-/home/synopsys/vcs/vcs_vV-2023.12-SP1/vcs/V-2023.12-SP1}
export VCS=$VCS_HOME
export VCS_TARGET_ARCH=linux64

# UVM: this checkout's default VCS_UVMHOME_ARG points at a nonexistent path.
export UVM_HOME=${CV_LOCAL_UVM_HOME:-$VCS_HOME/etc/uvm}

# --- stale values that silently win over the defaults above ----------------
unset RISCV_GCC SUITEDIR IMPERASD_LICENSE_FILE

# Put both bin directories first, dropping any earlier copy: an ambient PATH may
# already carry a different riscv-none-embed-gcc (e.g. the SiFive toolchain),
# and CV_SW_PREFIX resolves the compiler through PATH. Idempotent.
_cv_keep=
_cv_old_ifs=$IFS
IFS=:
for _cv_dir in $PATH; do
    case $_cv_dir in
        ""|"$VCS_HOME/bin"|"$CV_SW_TOOLCHAIN/bin") ;;
        *) _cv_keep=${_cv_keep:+$_cv_keep:}$_cv_dir ;;
    esac
done
IFS=$_cv_old_ifs
PATH=$CV_SW_TOOLCHAIN/bin:$VCS_HOME/bin${_cv_keep:+:}$_cv_keep
export PATH
unset _cv_keep _cv_old_ifs _cv_dir

# --- helper ----------------------------------------------------------------
# rustiss_case <test> [extra make args...]
# Runs one program from cv32e40p/tests/programs/custom with ISS=RUSTISS and
# leaves the log at /tmp/rustiss-<test>.log.
rustiss_case() {
    local test=${1:?usage: rustiss_case <test> [extra make args...]}
    shift
    ( cd "$_CV_SIM_UVMT" || return 1
      make test TEST="$test" ISS=RUSTISS VCS_UVMHOME_ARG="$UVM_HOME" "$@" \
          > "/tmp/rustiss-$test.log" 2>&1
      local rc=$?
      grep -ohE 'SIMULATION (PASSED|FAILED)[A-Z ]*' "/tmp/rustiss-$test.log" | tail -1
      echo "exit=$rc  log=/tmp/rustiss-$test.log"
      return $rc )
}

# Rebuild the DPI model after editing rust-iss/src and install it back here.
rustiss_rebuild() {
    ( cd "${RUSTISS_SRC:-/home/liboeda/libo/Ai/omp_rea/imperas-riscv-tests/rust-iss}" || return 1
      cargo build --release || return 1
      install -m 0755 target/release/libcv32dpi.so \
          "$_CV_ROOT/vendor_lib/rustiss/bin/libcv32dpi.so" ) &&
    echo "installed $_CV_ROOT/vendor_lib/rustiss/bin/libcv32dpi.so"
}