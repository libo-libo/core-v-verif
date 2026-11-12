/*
 * Copyright 2026 OpenHW Group contributors.
 *
 * Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://solderpad.org/licenses/
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * RVVI adapter for the open-source Rust instruction set simulator
 * (imperas-riscv-tests/rust-iss, cv32dpi crate).
 *
 * This file occupies the same place as vendored imperas_DV_COREV/sv/imperas_CV32.sv,
 * but its DPI boundary carries only scalars: no C structs cross the boundary, so
 * no struct layout can drift between the simulator and the SV side. The RVVI
 * interface declarations below are re-declared here because the vendored file
 * that normally provides them is not compiled in this flow.
 *
 * Rust side contract (rust-iss/src/dpi.rs):
 *   imports (SV -> Rust): svimp_entry, svimp_exit
 *   exports (Rust -> SV): svexp_step, svexp_dmiWrite, svexp_setGPR, svexp_setCSR,
 *                         svexp_setDECODE, svexp_setRESULT
 *
 * The model owns its own memory image: `svimp_entry` loads the ELF through
 * svexp_dmiWrite and runs to completion, one instruction per svexp_step. Nothing
 * drives `bus`, so the `RVVI_memory` inside ram.sv changes only over DMI -- which
 * is exactly where monitor.sv reads its signature from. The port stays in the
 * module header because uvmt_cv32e40p_iss_wrap.sv instantiates both ISS options
 * with the same `(bus, io)` shape.
 */

`include "typedefs.sv"

`ifndef DMI_RAM_PATH
  `define DMI_RAM_PATH ram.memory.mem
`endif

interface RVVI_state #(
    parameter int ILEN = 32,
    parameter int XLEN = 32
);
    event            notify;

    bit              valid; // Retired instruction
    bit              trap;  // Trapped instruction
    bit              halt;  // Halted  instruction

    bit              intr;  // Flag first instruction of trap handler
    bit [(XLEN-1):0] order;
    bit [(ILEN-1):0] insn;
    bit [2:0]        isize;
    bit [1:0]        mode;
    bit [1:0]        ixl;

    string           decode;

    bit [(XLEN-1):0] pc;
    bit [(XLEN-1):0] pcnext;

    bit [(XLEN-1):0] x[32];
    bit [(XLEN-1):0] f[32];
    bit [(XLEN-1):0] c[bit[11:0]];
    bit [(XLEN-1):0] csr[string];

    // Volatile CSR reads are served from the RTL register file.
    bit [31:0] GPR_rtl[32];
endinterface

typedef enum { IDLE, STEPI, STOP, CONT } rvvi_c_e;

interface RVVI_control;
    event     notify;

    rvvi_c_e  cmd;
    bit       ssmode;

    bit       state_idle;
    bit       state_stepi;
    bit       state_stop;
    bit       state_cont;

    initial ssmode = 1;

    always @(cmd) begin
        state_idle  = (cmd == IDLE);
        state_stepi = (cmd == STEPI);
        state_stop  = (cmd == STOP);
        state_cont  = (cmd == CONT);
    end

    function automatic void idle();
        cmd = IDLE;
        ->notify;
    endfunction

    function automatic void stepi();
        cmd = STEPI;
        ->notify;
    endfunction

    function automatic void stop();
        cmd = STOP;
        ssmode = 1;
        ->notify;
    endfunction

    function automatic void cont();
        cmd = CONT;
        ssmode = 0;
        ->notify;
    endfunction
endinterface

interface RVVI_io;
    bit         reset;
    bit  [31:0] reset_addr;
    bit         nmi;
    bit  [31:0] nmi_cause;
    bit  [31:0] nmi_addr;

    bit  [31:0] irq_i;     // Active high level sensitive interrupt inputs
    bit         irq_ack_o; // Interrupt acknowledge
    bit  [4:0]  irq_id_o;  // Interrupt index for taken interrupt
    bit         deferint;  // Gates the last stage of interrupt

    bit         haltreq;
    bit         resethaltreq;
    bit         DM;

    bit         LoadBusFaultNMI;
    bit         StoreBusFaultNMI;
    bit         InstructionBusFault;

    bit         Shutdown;
endinterface

interface RVVI_bus;
    bit     Clk;

    bit     [31:0] DAddr;
    bit     [31:0] DData;
    bit     [3:0]  Dbe;
    bit     [2:0]  DSize;
    bit            Dwr;
    bit            Drd;

    bit     [31:0] IAddr;
    bit     [31:0] IData;
    bit     [3:0]  Ibe;
    bit     [2:0]  ISize;
    bit            Ird;
endinterface

module CPU #(
    parameter int ID = 0,
    parameter string VARIANT = "UNSET"
)(
    RVVI_bus bus,
    RVVI_io  io
);

`ifdef UVM
    import uvm_pkg::*;
`endif

    import "DPI-C" context task           svimp_entry(input string cfg, input string elf, input string variant);
    import "DPI-C" context function void  svimp_exit();

    export "DPI-C" task     svexp_step;
    export "DPI-C" function svexp_dmiWrite;

    export "DPI-C" function svexp_setGPR;
    export "DPI-C" function svexp_setCSR;
    export "DPI-C" function svexp_setDECODE;
    export "DPI-C" task     svexp_setRESULT;

    RVVI_state   state();
    RVVI_control control();

    // The step-and-compare FSM deposits the retired RTL instruction's cycle
    // count here before ordering each model step
    // (uvmt_cv32e40p_step_compare.sv:399). Nothing reads it back; it stays
    // declared because that hierarchical write requires the variable to exist.
    bit [31:0] cycles;

    // One instruction of model progress per call. Wait for a step command rather
    // than a clock edge: while the step-and-compare FSM drives the model,
    // `uvma_clknrst_if.stop_clk()` holds `bus.Clk` at a constant level, so
    // `@(posedge bus.Clk)` would never return.
    task svexp_step;
        while (control.cmd != STEPI) @(control.notify);
    endtask

    //
    // Back door access for image loading and store mirroring
    //
    // Addresses are `int unsigned` so `address >> 2` is a logical shift: the RAM
    // is a word-indexed associative array, and `MONITOR` indexes it the same way
    // from a `bit [31:0]` address.
    function automatic void svexp_dmiWrite(input int unsigned address, input int data);
        `DMI_RAM_PATH[address >> 2] = data;
    endfunction

    //
    // Reporting
    //
    function automatic void svexp_setDECODE(input string value, input int insn, input int isize);
        state.decode = value;
        state.insn   = insn;
        state.isize  = isize;
    endfunction

    function automatic void svexp_setGPR(input int index, input longint value);
        state.x[index] = value;
    endfunction

    function automatic void svexp_setCSR(input string name, input int index, input longint value);
        state.csr[name] = value;
        state.c[index]  = value;
    endfunction

    task svexp_setRESULT;
        input int     isvalid;
        input longint retpc;
        input longint excpc;
        input longint nextpc;
        input longint order;
        input int     irq_ack;
        input int     irq_id;
        input int     dm;

        control.idle();

        io.irq_ack_o = irq_ack;
        io.irq_id_o  = irq_id;
        io.DM        = dm;

        if (isvalid) begin
            state.valid = 1;
            state.trap  = 0;
            state.pc    = retpc;
        end else begin
            state.valid = 0;
            state.trap  = 1;
            state.pc    = excpc;
        end

        state.pcnext = nextpc;
        state.order  = order;

        ->state.notify;
    endtask

    //
    // Startup
    //
    string elf_file;

    function automatic void msgfatal(input string msg);
    `ifdef UVM
        `uvm_fatal(VARIANT, msg);
    `else
        $display("%s: %s", VARIANT, msg);
        $fatal;
    `endif
    endfunction

    function automatic void plusarg_elf();
        if (!($value$plusargs("elf_file=%s", elf_file))) begin
            msgfatal("+elf_file=<elf filename> is required");
        end
    endfunction

    string ovpcfg;

    function automatic void plusarg_ovpcfg();
        ovpcfg = "";
        if ($value$plusargs("ovpcfg=%s", ovpcfg)) ;
    endfunction

    initial begin
        if (!$test$plusargs("DISABLE_OVPSIM")) begin
            #1;
            plusarg_ovpcfg();
            plusarg_elf();
            svimp_entry(ovpcfg, elf_file, VARIANT);
        end
    end

    final begin
        svimp_exit();
    end

endmodule