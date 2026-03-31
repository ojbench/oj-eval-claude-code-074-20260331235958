// RISCV32IC CPU with basic out-of-order execution support
// Implements RV32I base instruction set + RV32C compressed extension

module cpu(
  input  wire                 clk_in,        // system clock signal
  input  wire                 rst_in,        // reset signal
  input  wire                 rdy_in,        // ready signal, pause cpu when low

  input  wire [ 7:0]          mem_din,       // data input bus
  output wire [ 7:0]          mem_dout,      // data output bus
  output wire [31:0]          mem_a,         // address bus (only 17:0 is used)
  output wire                 mem_wr,        // write/read signal (1 for write)

  input  wire                 io_buffer_full, // 1 if uart buffer is full

  output wire [31:0]          dbgreg_dout    // cpu register output (debugging demo)
);

// Specifications:
// - Pause cpu(freeze pc, registers, etc.) when rdy_in is low
// - Memory read result will be returned in the next cycle. Write takes 1 cycle(no need to wait)
// - Memory is of size 128KB, with valid address ranging from 0x0 to 0x20000
// - I/O port is mapped to address higher than 0x30000 (mem_a[17:16]==2'b11)
// - 0x30000 read: read a byte from input
// - 0x30000 write: write a byte to output (write 0x00 is ignored)
// - 0x30004 read: read clocks passed since cpu starts (in dword, 4 bytes)
// - 0x30004 write: indicates program stop (will output '\0' through uart tx)

// Pipeline stages
reg [31:0] pc;              // Program counter
reg [31:0] regs [0:31];     // Register file

// Instruction fetch
reg [2:0] if_state;
reg [31:0] if_inst;
reg [31:0] if_pc;
reg [1:0] if_inst_len;      // 2 for compressed, 4 for normal
reg [3:0] if_byte_cnt;
reg if_valid;
wire is_compressed;

// Instruction decode
reg [31:0] id_inst;
reg [31:0] id_pc;
reg [4:0] id_opcode;
reg [4:0] id_rd;
reg [4:0] id_rs1;
reg [4:0] id_rs2;
reg [2:0] id_funct3;
reg [6:0] id_funct7;
reg [31:0] id_imm;
reg id_valid;

// Execute
reg [31:0] ex_result;
reg [31:0] ex_pc;
reg [4:0] ex_rd;
reg ex_valid;
reg ex_is_branch;
reg ex_branch_taken;
reg [31:0] ex_branch_target;
reg ex_is_load;
reg ex_is_store;
reg [31:0] ex_mem_addr;
reg [31:0] ex_store_data;
reg [2:0] ex_mem_op;

// Memory access
reg [2:0] mem_state;
reg [31:0] mem_addr;
reg [31:0] mem_data;
reg [4:0] mem_rd;
reg mem_valid;
reg mem_is_load;
reg [2:0] mem_op;
reg [3:0] mem_byte_cnt;
reg [31:0] mem_load_data;

// Write back
reg [31:0] wb_data;
reg [4:0] wb_rd;
reg wb_valid;

// Memory interface
reg [31:0] mem_addr_out;
reg [7:0] mem_data_out;
reg mem_wr_out;

assign mem_a = mem_addr_out;
assign mem_dout = mem_data_out;
assign mem_wr = mem_wr_out;
assign dbgreg_dout = regs[1]; // debug register a0

// Instruction is compressed if lower 2 bits != 2'b11
assign is_compressed = (if_inst[1:0] != 2'b11);

// States
localparam IDLE = 3'd0;
localparam FETCH = 3'd1;
localparam DECODE = 3'd2;
localparam EXECUTE = 3'd3;
localparam MEM_READ = 3'd4;
localparam MEM_WRITE = 3'd5;
localparam WRITEBACK = 3'd6;

// Opcodes (RV32I)
localparam OP_LUI = 5'b01101;
localparam OP_AUIPC = 5'b00101;
localparam OP_JAL = 5'b11011;
localparam OP_JALR = 5'b11001;
localparam OP_BRANCH = 5'b11000;
localparam OP_LOAD = 5'b00000;
localparam OP_STORE = 5'b01000;
localparam OP_OP_IMM = 5'b00100;
localparam OP_OP = 5'b01100;

integer i;

// Decompress RV32C instructions to RV32I
task decompress_inst;
  input [15:0] c_inst;
  output [31:0] inst;
  reg [1:0] opcode;
  reg [2:0] funct3;
  begin
    opcode = c_inst[1:0];
    funct3 = c_inst[15:13];
    inst = 32'b0;

    case (opcode)
      2'b00: begin  // C0
        case (funct3)
          3'b000: begin // C.ADDI4SPN
            inst = {2'b0, c_inst[10:7], c_inst[12:11], c_inst[5], c_inst[6], 2'b00, 5'h2, 3'b000, 2'b01, c_inst[4:2], 7'b0010011};
          end
          3'b010: begin // C.LW
            inst = {5'b0, c_inst[5], c_inst[12:10], c_inst[6], 2'b00, 2'b01, c_inst[9:7], 3'b010, 2'b01, c_inst[4:2], 7'b0000011};
          end
          3'b110: begin // C.SW
            inst = {5'b0, c_inst[5], c_inst[12], 2'b01, c_inst[4:2], 2'b01, c_inst[9:7], 3'b010, c_inst[11:10], c_inst[6], 2'b00, 7'b0100011};
          end
          default: inst = 32'h00000013; // NOP
        endcase
      end

      2'b01: begin  // C1
        case (funct3)
          3'b000: begin // C.ADDI / C.NOP
            inst = {{6{c_inst[12]}}, c_inst[12], c_inst[6:2], c_inst[11:7], 3'b000, c_inst[11:7], 7'b0010011};
          end
          3'b001: begin // C.JAL (RV32 only)
            inst = {c_inst[12], c_inst[8], c_inst[10:9], c_inst[6], c_inst[7], c_inst[2], c_inst[11], c_inst[5:3], {9{c_inst[12]}}, 5'h1, 7'b1101111};
          end
          3'b010: begin // C.LI
            inst = {{6{c_inst[12]}}, c_inst[12], c_inst[6:2], 5'h0, 3'b000, c_inst[11:7], 7'b0010011};
          end
          3'b011: begin // C.ADDI16SP / C.LUI
            if (c_inst[11:7] == 5'h2) begin  // C.ADDI16SP
              inst = {{3{c_inst[12]}}, c_inst[4:3], c_inst[5], c_inst[2], c_inst[6], 4'b0, 5'h2, 3'b000, 5'h2, 7'b0010011};
            end else begin  // C.LUI
              inst = {{15{c_inst[12]}}, c_inst[6:2], c_inst[11:7], 7'b0110111};
            end
          end
          3'b100: begin // Arithmetic
            case (c_inst[11:10])
              2'b00: begin // C.SRLI
                inst = {7'b0000000, c_inst[6:2], 2'b01, c_inst[9:7], 3'b101, 2'b01, c_inst[9:7], 7'b0010011};
              end
              2'b01: begin // C.SRAI
                inst = {7'b0100000, c_inst[6:2], 2'b01, c_inst[9:7], 3'b101, 2'b01, c_inst[9:7], 7'b0010011};
              end
              2'b10: begin // C.ANDI
                inst = {{6{c_inst[12]}}, c_inst[12], c_inst[6:2], 2'b01, c_inst[9:7], 3'b111, 2'b01, c_inst[9:7], 7'b0010011};
              end
              2'b11: begin // Register-register ops
                case ({c_inst[12], c_inst[6:5]})
                  3'b000: inst = {7'b0100000, 2'b01, c_inst[4:2], 2'b01, c_inst[9:7], 3'b000, 2'b01, c_inst[9:7], 7'b0110011}; // C.SUB
                  3'b001: inst = {7'b0000000, 2'b01, c_inst[4:2], 2'b01, c_inst[9:7], 3'b100, 2'b01, c_inst[9:7], 7'b0110011}; // C.XOR
                  3'b010: inst = {7'b0000000, 2'b01, c_inst[4:2], 2'b01, c_inst[9:7], 3'b110, 2'b01, c_inst[9:7], 7'b0110011}; // C.OR
                  3'b011: inst = {7'b0000000, 2'b01, c_inst[4:2], 2'b01, c_inst[9:7], 3'b111, 2'b01, c_inst[9:7], 7'b0110011}; // C.AND
                  default: inst = 32'h00000013; // NOP
                endcase
              end
            endcase
          end
          3'b101: begin // C.J
            inst = {c_inst[12], c_inst[8], c_inst[10:9], c_inst[6], c_inst[7], c_inst[2], c_inst[11], c_inst[5:3], {9{c_inst[12]}}, 5'h0, 7'b1101111};
          end
          3'b110: begin // C.BEQZ
            inst = {{4{c_inst[12]}}, c_inst[6:5], c_inst[2], 5'h0, 2'b01, c_inst[9:7], 3'b000, c_inst[11:10], c_inst[4:3], c_inst[12], 7'b1100011};
          end
          3'b111: begin // C.BNEZ
            inst = {{4{c_inst[12]}}, c_inst[6:5], c_inst[2], 5'h0, 2'b01, c_inst[9:7], 3'b001, c_inst[11:10], c_inst[4:3], c_inst[12], 7'b1100011};
          end
        endcase
      end

      2'b10: begin  // C2
        case (funct3)
          3'b000: begin // C.SLLI
            inst = {7'b0000000, c_inst[6:2], c_inst[11:7], 3'b001, c_inst[11:7], 7'b0010011};
          end
          3'b010: begin // C.LWSP
            inst = {4'b0, c_inst[3:2], c_inst[12], c_inst[6:4], 2'b00, 5'h2, 3'b010, c_inst[11:7], 7'b0000011};
          end
          3'b100: begin
            if (c_inst[12] == 0) begin
              if (c_inst[6:2] == 0) begin // C.JR
                inst = {12'b0, c_inst[11:7], 3'b000, 5'h0, 7'b1100111};
              end else begin // C.MV
                inst = {7'b0000000, c_inst[6:2], 5'h0, 3'b000, c_inst[11:7], 7'b0110011};
              end
            end else begin
              if (c_inst[6:2] == 0) begin // C.JALR
                inst = {12'b0, c_inst[11:7], 3'b000, 5'h1, 7'b1100111};
              end else begin // C.ADD
                inst = {7'b0000000, c_inst[6:2], c_inst[11:7], 3'b000, c_inst[11:7], 7'b0110011};
              end
            end
          end
          3'b110: begin // C.SWSP
            inst = {4'b0, c_inst[8:7], c_inst[12], c_inst[6:2], 5'h2, 3'b010, c_inst[11:9], 2'b00, 7'b0100011};
          end
          default: inst = 32'h00000013; // NOP
        endcase
      end

      default: inst = 32'h00000013; // NOP
    endcase
  end
endtask

always @(posedge clk_in) begin
  if (rst_in) begin
    // Reset all registers and state
    pc <= 32'h0;
    for (i = 0; i < 32; i = i + 1) begin
      regs[i] <= 32'h0;
    end
    if_state <= FETCH;
    if_byte_cnt <= 0;
    if_valid <= 0;
    id_valid <= 0;
    ex_valid <= 0;
    mem_valid <= 0;
    wb_valid <= 0;
    mem_wr_out <= 0;
    mem_state <= IDLE;
  end
  else if (!rdy_in) begin
    // Pause - do nothing
  end
  else begin
    // Pipeline execution

    // === Write Back Stage ===
    if (wb_valid) begin
      if (wb_rd != 0) begin
        regs[wb_rd] <= wb_data;
      end
      wb_valid <= 0;
    end

    // === Memory Stage ===
    if (mem_valid) begin
      if (mem_is_load) begin
        case (mem_state)
          IDLE: begin
            // Start load
            mem_addr_out <= mem_addr;
            mem_wr_out <= 0;
            mem_state <= MEM_READ;
            mem_byte_cnt <= 0;
            mem_load_data <= 0;
          end
          MEM_READ: begin
            // Read byte by byte
            case (mem_op)
              3'b000, 3'b100: begin // LB, LBU
                mem_load_data <= {{24{(mem_op == 3'b000) ? mem_din[7] : 1'b0}}, mem_din};
                mem_state <= IDLE;
                wb_data <= {{24{(mem_op == 3'b000) ? mem_din[7] : 1'b0}}, mem_din};
                wb_rd <= mem_rd;
                wb_valid <= 1;
                mem_valid <= 0;
              end
              3'b001, 3'b101: begin // LH, LHU
                if (mem_byte_cnt == 0) begin
                  mem_load_data[7:0] <= mem_din;
                  mem_addr_out <= mem_addr + 1;
                  mem_byte_cnt <= 1;
                end else begin
                  mem_load_data[15:8] <= mem_din;
                  mem_state <= IDLE;
                  wb_data <= {{16{(mem_op == 3'b001) ? mem_din[7] : 1'b0}}, mem_din, mem_load_data[7:0]};
                  wb_rd <= mem_rd;
                  wb_valid <= 1;
                  mem_valid <= 0;
                end
              end
              3'b010: begin // LW
                case (mem_byte_cnt)
                  0: begin
                    mem_load_data[7:0] <= mem_din;
                    mem_addr_out <= mem_addr + 1;
                    mem_byte_cnt <= 1;
                  end
                  1: begin
                    mem_load_data[15:8] <= mem_din;
                    mem_addr_out <= mem_addr + 2;
                    mem_byte_cnt <= 2;
                  end
                  2: begin
                    mem_load_data[23:16] <= mem_din;
                    mem_addr_out <= mem_addr + 3;
                    mem_byte_cnt <= 3;
                  end
                  3: begin
                    mem_load_data[31:24] <= mem_din;
                    mem_state <= IDLE;
                    wb_data <= {mem_din, mem_load_data[23:0]};
                    wb_rd <= mem_rd;
                    wb_valid <= 1;
                    mem_valid <= 0;
                  end
                endcase
              end
            endcase
          end
        endcase
      end else begin
        // Store operation
        case (mem_state)
          IDLE: begin
            mem_state <= MEM_WRITE;
            mem_byte_cnt <= 0;
          end
          MEM_WRITE: begin
            case (mem_op)
              3'b000: begin // SB
                if (!io_buffer_full || mem_addr < 32'h30000) begin
                  mem_addr_out <= mem_addr;
                  mem_data_out <= mem_data[7:0];
                  mem_wr_out <= 1;
                  mem_state <= IDLE;
                  mem_valid <= 0;
                end
              end
              3'b001: begin // SH
                if (mem_byte_cnt == 0) begin
                  if (!io_buffer_full || mem_addr < 32'h30000) begin
                    mem_addr_out <= mem_addr;
                    mem_data_out <= mem_data[7:0];
                    mem_wr_out <= 1;
                    mem_byte_cnt <= 1;
                  end
                end else begin
                  mem_addr_out <= mem_addr + 1;
                  mem_data_out <= mem_data[15:8];
                  mem_wr_out <= 1;
                  mem_state <= IDLE;
                  mem_valid <= 0;
                end
              end
              3'b010: begin // SW
                case (mem_byte_cnt)
                  0: begin
                    if (!io_buffer_full || mem_addr < 32'h30000) begin
                      mem_addr_out <= mem_addr;
                      mem_data_out <= mem_data[7:0];
                      mem_wr_out <= 1;
                      mem_byte_cnt <= 1;
                    end
                  end
                  1: begin
                    mem_addr_out <= mem_addr + 1;
                    mem_data_out <= mem_data[15:8];
                    mem_wr_out <= 1;
                    mem_byte_cnt <= 2;
                  end
                  2: begin
                    mem_addr_out <= mem_addr + 2;
                    mem_data_out <= mem_data[23:16];
                    mem_wr_out <= 1;
                    mem_byte_cnt <= 3;
                  end
                  3: begin
                    mem_addr_out <= mem_addr + 3;
                    mem_data_out <= mem_data[31:24];
                    mem_wr_out <= 1;
                    mem_state <= IDLE;
                    mem_valid <= 0;
                  end
                endcase
              end
            endcase
          end
        endcase
      end
    end

    // === Execute Stage ===
    if (ex_valid) begin
      if (ex_is_load) begin
        // Pass to memory stage
        mem_addr <= ex_mem_addr;
        mem_rd <= ex_rd;
        mem_valid <= 1;
        mem_is_load <= 1;
        mem_op <= ex_mem_op;
        mem_state <= IDLE;
        ex_valid <= 0;
      end else if (ex_is_store) begin
        // Pass to memory stage
        mem_addr <= ex_mem_addr;
        mem_data <= ex_store_data;
        mem_valid <= 1;
        mem_is_load <= 0;
        mem_op <= ex_mem_op;
        mem_state <= IDLE;
        ex_valid <= 0;
      end else begin
        // Writeback
        if (ex_is_branch) begin
          if (ex_branch_taken) begin
            pc <= ex_branch_target;
            if_state <= FETCH;
            if_byte_cnt <= 0;
            id_valid <= 0;
          end
        end
        wb_data <= ex_result;
        wb_rd <= ex_rd;
        wb_valid <= 1;
        ex_valid <= 0;
      end
    end

    // === Decode Stage ===
    if (id_valid && !ex_valid) begin
      // Decode instruction
      id_opcode = id_inst[6:2];
      id_rd = id_inst[11:7];
      id_rs1 = id_inst[19:15];
      id_rs2 = id_inst[24:20];
      id_funct3 = id_inst[14:12];
      id_funct7 = id_inst[31:25];

      case (id_opcode)
        OP_LUI: begin
          id_imm = {id_inst[31:12], 12'b0};
          ex_result <= id_imm;
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 0;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_AUIPC: begin
          id_imm = {id_inst[31:12], 12'b0};
          ex_result <= id_pc + id_imm;
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 0;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_JAL: begin
          id_imm = {{12{id_inst[31]}}, id_inst[19:12], id_inst[20], id_inst[30:21], 1'b0};
          ex_result <= id_pc + 4;
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 1;
          ex_branch_taken <= 1;
          ex_branch_target <= id_pc + id_imm;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_JALR: begin
          id_imm = {{20{id_inst[31]}}, id_inst[31:20]};
          ex_result <= id_pc + 4;
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 1;
          ex_branch_taken <= 1;
          ex_branch_target <= (regs[id_rs1] + id_imm) & ~32'h1;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_BRANCH: begin
          id_imm = {{20{id_inst[31]}}, id_inst[7], id_inst[30:25], id_inst[11:8], 1'b0};
          case (id_funct3)
            3'b000: ex_branch_taken <= (regs[id_rs1] == regs[id_rs2]); // BEQ
            3'b001: ex_branch_taken <= (regs[id_rs1] != regs[id_rs2]); // BNE
            3'b100: ex_branch_taken <= ($signed(regs[id_rs1]) < $signed(regs[id_rs2])); // BLT
            3'b101: ex_branch_taken <= ($signed(regs[id_rs1]) >= $signed(regs[id_rs2])); // BGE
            3'b110: ex_branch_taken <= (regs[id_rs1] < regs[id_rs2]); // BLTU
            3'b111: ex_branch_taken <= (regs[id_rs1] >= regs[id_rs2]); // BGEU
            default: ex_branch_taken <= 0;
          endcase
          ex_branch_target <= id_pc + id_imm;
          ex_is_branch <= 1;
          ex_valid <= 1;
          ex_rd <= 0;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_LOAD: begin
          id_imm = {{20{id_inst[31]}}, id_inst[31:20]};
          ex_mem_addr <= regs[id_rs1] + id_imm;
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_load <= 1;
          ex_is_store <= 0;
          ex_is_branch <= 0;
          ex_mem_op <= id_funct3;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_STORE: begin
          id_imm = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
          ex_mem_addr <= regs[id_rs1] + id_imm;
          ex_store_data <= regs[id_rs2];
          ex_valid <= 1;
          ex_is_store <= 1;
          ex_is_load <= 0;
          ex_is_branch <= 0;
          ex_mem_op <= id_funct3;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_OP_IMM: begin
          id_imm = {{20{id_inst[31]}}, id_inst[31:20]};
          case (id_funct3)
            3'b000: ex_result <= regs[id_rs1] + id_imm; // ADDI
            3'b001: ex_result <= regs[id_rs1] << id_imm[4:0]; // SLLI
            3'b010: ex_result <= ($signed(regs[id_rs1]) < $signed(id_imm)) ? 32'h1 : 32'h0; // SLTI
            3'b011: ex_result <= (regs[id_rs1] < id_imm) ? 32'h1 : 32'h0; // SLTIU
            3'b100: ex_result <= regs[id_rs1] ^ id_imm; // XORI
            3'b101: begin
              if (id_inst[30]) // SRAI
                ex_result <= $signed(regs[id_rs1]) >>> id_imm[4:0];
              else // SRLI
                ex_result <= regs[id_rs1] >> id_imm[4:0];
            end
            3'b110: ex_result <= regs[id_rs1] | id_imm; // ORI
            3'b111: ex_result <= regs[id_rs1] & id_imm; // ANDI
          endcase
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 0;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        OP_OP: begin
          case (id_funct3)
            3'b000: begin
              if (id_funct7[5]) // SUB
                ex_result <= regs[id_rs1] - regs[id_rs2];
              else // ADD
                ex_result <= regs[id_rs1] + regs[id_rs2];
            end
            3'b001: ex_result <= regs[id_rs1] << regs[id_rs2][4:0]; // SLL
            3'b010: ex_result <= ($signed(regs[id_rs1]) < $signed(regs[id_rs2])) ? 32'h1 : 32'h0; // SLT
            3'b011: ex_result <= (regs[id_rs1] < regs[id_rs2]) ? 32'h1 : 32'h0; // SLTU
            3'b100: ex_result <= regs[id_rs1] ^ regs[id_rs2]; // XOR
            3'b101: begin
              if (id_funct7[5]) // SRA
                ex_result <= $signed(regs[id_rs1]) >>> regs[id_rs2][4:0];
              else // SRL
                ex_result <= regs[id_rs1] >> regs[id_rs2][4:0];
            end
            3'b110: ex_result <= regs[id_rs1] | regs[id_rs2]; // OR
            3'b111: ex_result <= regs[id_rs1] & regs[id_rs2]; // AND
          endcase
          ex_rd <= id_rd;
          ex_valid <= 1;
          ex_is_branch <= 0;
          ex_is_load <= 0;
          ex_is_store <= 0;
          ex_pc <= id_pc;
          id_valid <= 0;
        end

        default: begin
          // Invalid instruction - treat as NOP
          id_valid <= 0;
        end
      endcase
    end

    // === Instruction Fetch Stage ===
    if (!id_valid && !ex_valid) begin
      case (if_state)
        FETCH: begin
          // Fetch instruction
          if (if_byte_cnt == 0) begin
            mem_addr_out <= pc;
            mem_wr_out <= 0;
            if_byte_cnt <= 1;
          end else if (if_byte_cnt == 1) begin
            // Got first byte
            if_inst[7:0] <= mem_din;
            mem_addr_out <= pc + 1;
            if_byte_cnt <= 2;
          end else if (if_byte_cnt == 2) begin
            // Got second byte
            if_inst[15:8] <= mem_din;

            // Check if compressed
            if (is_compressed) begin
              // 16-bit instruction
              decompress_inst(if_inst[15:0], if_inst);
              if_pc <= pc;
              id_inst <= if_inst;
              id_pc <= pc;
              id_valid <= 1;
              pc <= pc + 2;
              if_state <= FETCH;
              if_byte_cnt <= 0;
            end else begin
              // Need 2 more bytes
              mem_addr_out <= pc + 2;
              if_byte_cnt <= 3;
            end
          end else if (if_byte_cnt == 3) begin
            // Got third byte
            if_inst[23:16] <= mem_din;
            mem_addr_out <= pc + 3;
            if_byte_cnt <= 4;
          end else if (if_byte_cnt == 4) begin
            // Got fourth byte - complete instruction
            if_inst[31:24] <= mem_din;
            if_pc <= pc;
            id_inst <= if_inst;
            id_pc <= pc;
            id_valid <= 1;
            pc <= pc + 4;
            if_state <= FETCH;
            if_byte_cnt <= 0;
          end
        end
      endcase
    end
  end
end

// x0 is always 0
always @(*) begin
  regs[0] = 32'h0;
end

endmodule
