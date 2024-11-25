const Coordinates = @import("coordinates.zig").Coordinates(u32);
const board = @import("board.zig");
const std = @import("std");
const zobrist = @import("zobrist.zig");
const main = @import("main.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
const Allocator = gpa.allocator();

var evaluator: Evaluator = undefined;
var node: u32 = 0;
var alpha_cut: u32 = 0;
var beta_cut: u32 = 0;
var cumulative_cut_depth: u32 = 0;

const Head = enum {
    blocked,
    straight,
};

const Sequence = enum {
    five,
    four,
    three,
    two,
    poked_four,
    poked_three,
    poked_two,
    none,

    pub fn resolve(same: usize, gap: usize, gap_idx: usize) Sequence {
        if (gap > 1)
            return .none;
        if (gap == 1) {
            return switch (same) {
                2 => .poked_two,
                3 => .poked_three,
                4 => .poked_four,
                else => {
                    if (same > 5) {
                        if (gap_idx == 5 or same - gap_idx == 5) {
                            return .five;
                        }
                    }
                    return .none;
                },
            };
        } else { // gap == 0
            return switch (same) {
            2 => .two,
            3 => .three,
            4 => .four,
            5 => .five,
            else => .none,
        };
        }
    }

    pub fn toThreatType(self: Sequence, head: Head) Threat2 {
        return switch (head) {
            .blocked => switch (self) {
                .five => .five,
                .four => .blocked_four,
                .three => .blocked_three,
                .two => .blocked_two,
                .poked_four => .blocked_poked_four,
                .poked_three => .blocked_poked_three,
                .poked_two => .blocked_poked_two,
                .none => .none,
            },
            .straight => switch (self) {
                .five => .five,
                .four => .straight_four,
                .three => .straight_three,
                .two => .straight_two,
                .poked_four => .straight_poked_four,
                .poked_three => .straight_poked_three,
                .poked_two => .straight_poked_two,
                .none => .none,
            },
        };
    }
};

const Threat2 = enum {
    five,
    straight_four,
    straight_poked_four,
    blocked_four,
    blocked_poked_four,
    straight_three,
    straight_poked_three,
    blocked_three,
    blocked_poked_three,
    straight_two,
    straight_poked_two,
    blocked_two,
    blocked_poked_two,
    none,
};

const threat_weights = blk:{
    var weights: [14]i32 = undefined;
    weights[@intFromEnum(Threat2.five)] = 1e9;
    weights[@intFromEnum(Threat2.straight_four)] = 1e5;
    weights[@intFromEnum(Threat2.straight_poked_four)] = 1e4;
    weights[@intFromEnum(Threat2.blocked_four)] = 1e4;
    weights[@intFromEnum(Threat2.blocked_poked_four)] = 1e4;
    weights[@intFromEnum(Threat2.straight_three)] = 5e3;
    weights[@intFromEnum(Threat2.straight_poked_three)] = 5e3;
    weights[@intFromEnum(Threat2.blocked_three)] = 1670;
    weights[@intFromEnum(Threat2.blocked_poked_three)] = 1670;
    weights[@intFromEnum(Threat2.straight_two)] = 1500;
    weights[@intFromEnum(Threat2.straight_poked_two)] = 1500;
    weights[@intFromEnum(Threat2.blocked_two)] = 500;
    weights[@intFromEnum(Threat2.blocked_poked_two)] = 300;
    weights[@intFromEnum(Threat2.none)] = 0;
    break :blk weights;
};

const Pattern = struct {
    same: usize,
    gap: usize,
    start_idx: usize,
    end_idx: usize,
    gap_idx: usize,
};

pub const HashMapContext = struct {
    pub fn hash(_: @This(), key: []const board.Cell) u64 {
        var h = std.hash.Fnv1a_32.init();
        h.update(std.mem.sliceAsBytes(key));
        return h.final();
    }

    pub fn eql(_: @This(), a: []const board.Cell, b: []const board.Cell) bool {
        return std.mem.eql(board.Cell, a, b);
    }
};

const Evaluator = struct {
    seq_hash_map: std.HashMap([]const board.Cell, []Threat2, HashMapContext, 80),
    allocator: std.mem.Allocator,

    const win: i32 = 1e8;

    pub fn init(allocator: std.mem.Allocator) !Evaluator {
        return Evaluator{
            .seq_hash_map = std.HashMap([]const board.Cell, []Threat2, HashMapContext, 80).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        var it = self.seq_hash_map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.seq_hash_map.deinit();
    }

    fn val(_: *Evaluator, threat: Threat2) i32 {
        return threat_weights[@intFromEnum(threat)];
    }

    fn explore(x: i32, y: i32, coord: Coordinates, current_board: board.Board, player: board.Cell, seq: []board.Cell) u32 {
        const opponent = if (player == board.Cell.own) board.Cell.opponent else board.Cell.own;
        var empty: usize = 0;
        var nb_seq: u32 = 0;

        var i: i32 = 1;
        while (i <= 5) : (i += 1) {
            const cur_x = @as(i32, @intCast(coord.x)) + x * i;
            const cur_y = @as(i32, @intCast(coord.y)) + y * i;

            if (cur_x < 0 or cur_y < 0 or current_board.isCoordinatesOutside(@intCast(cur_x), @intCast(cur_y))) {
                seq[nb_seq] = opponent;
                nb_seq += 1;
                break;
            }

            const cell = current_board.getCellByCoordinates(@intCast(cur_x), @intCast(cur_y));
            switch (cell) {
                board.Cell.empty => {
                    seq[nb_seq] = board.Cell.empty;
                    nb_seq += 1;
                    if (empty > 0) {
                        break;
                    }
                    empty += 1;
                },
                else => {
                    seq[nb_seq] = cell;
                    nb_seq += 1;
                    if (cell == opponent) {
                        break;
                    }
                },
            }
        }

        return nb_seq;
    }

    fn genSequence(x1: i32, y1: i32, x2: i32, y2: i32, coord: Coordinates, current_board: board.Board, seq: []board.Cell, player: board.Cell) u32 {
        var seq_a: [5]board.Cell = undefined;
        const nb_seq_a = explore(x1, y1, coord, current_board, player, &seq_a);
        std.mem.reverse(board.Cell, seq_a[0..nb_seq_a]);

        var nb_seq: u32 = 0;
        @memcpy(seq[0..nb_seq_a], seq_a[0..nb_seq_a]);
        nb_seq += nb_seq_a;

        seq[nb_seq] = player;
        nb_seq += 1;

        var seq_b: [5]board.Cell = undefined;
        const nb_seq_b = explore(x2, y2, coord, current_board, player, &seq_b);
        @memcpy(seq[nb_seq..nb_seq + nb_seq_b], seq_b[0..nb_seq_b]);
        nb_seq += nb_seq_b;

        return nb_seq;
    }

    fn analyze(self: *Evaluator, current_board: board.Board, player: board.Cell, coord: Coordinates, threats: []Threat2) !u32 {
        var sequences: [4][11]board.Cell = undefined;
        var sequences_len: [4]u32 = undefined;

        // Generate all sequences at once
        // Horizontal (from left to right)
        sequences_len[0] = genSequence(-1, 0, 1, 0, coord, current_board, &sequences[0], player);
        // Vertical (from top to bottom)
        sequences_len[1] = genSequence(0, -1, 0, 1, coord, current_board, &sequences[1], player);
        // Diagonal (from lower left to upper right)
        sequences_len[2] = genSequence(-1, 1, 1, -1, coord, current_board, &sequences[2], player);
        // Diagonal (from upper left to lower right)
        sequences_len[3] = genSequence(-1, -1, 1, 1, coord, current_board, &sequences[3], player);

        var nb_threats: u32 = 0;
        for (sequences, 0..) |seq, i| {
            const seq_threats = try self.cacheOrGet(player, seq[0..sequences_len[i]]);
            @memcpy(threats[nb_threats..nb_threats + seq_threats.len], seq_threats);
            nb_threats += @intCast(seq_threats.len);
            self.allocator.free(seq_threats);
        }

        return nb_threats;
    }

    pub fn evaluate(self: *Evaluator, current_board: board.Board, player: board.Cell, coord: Coordinates) !i32 {
        var threats: [64]Threat2 = undefined; // 64 is magic number
        const nb_threats = try self.analyze(current_board, player, coord, &threats);
        // defer self.allocator.free(threats);

        var total: i32 = 0;
        var i: u32 = 0;
        while (i < nb_threats) : (i += 1) {
            total += self.val(threats[i]);
        }
        return total;
    }

    fn cacheOrGet(self: *Evaluator, player: board.Cell, seq: []const board.Cell) ![]Threat2 {
        if (self.seq_hash_map.get(seq)) |cached| {
            return self.allocator.dupe(Threat2, cached);
        } else {
            const threats = try self.analyzeThreats(seq, player);
            try self.seq_hash_map.put(try Allocator.dupe(board.Cell, seq), threats);
            return self.allocator.dupe(Threat2, threats);
        }
    }

    fn findPatterns(seq: []const board.Cell, a: usize, b: usize, patterns: []Pattern, player: board.Cell) u32 {
        var gap: usize = 0;
        var same: usize = 0;
        var started = false;
        var start_idx: usize = 0;
        var end_idx: usize = 0;
        var pending_gap: usize = 0;
        var gap_idx: usize = 0;
        var nb_pattern: u32 = 0;

        var i: usize = a;
        while (i <= b) : (i += 1) {
            const cell = seq[i];

            if (cell == .empty) {
                if (started) {
                    pending_gap += 1;
                }
            } else {
                same += 1;
                gap += pending_gap;
                if (gap > 1) {
                    end_idx = i - 2;

                    if (same - 1 > 1) {
                        patterns[nb_pattern] = .{
                            .same = same - 1,
                            .gap = 1,
                            .start_idx = start_idx,
                            .end_idx = end_idx,
                            .gap_idx = gap_idx,
                        };
                        nb_pattern += 1;
                    }

                    start_idx = end_idx;
                    var tmp: usize = 0;
                    while (start_idx > 0 and seq[start_idx - 1] == player) {
                        start_idx -= 1;
                        tmp += 1;
                    }
                    end_idx = start_idx;
                    same = tmp + 1;
                    gap = 1;
                }
                if (pending_gap == 1) {
                    gap_idx = i - 1 - start_idx;
                }
                pending_gap = 0;

                if (!started) {
                    start_idx = i;
                }
                started = true;
            }

            if (pending_gap > 1) {
                end_idx = i - pending_gap;
                if (same > 1) {
                    patterns[nb_pattern] = .{
                        .same = same,
                        .gap = gap,
                        .start_idx = start_idx,
                        .end_idx = end_idx,
                        .gap_idx = gap_idx,
                    };
                    nb_pattern += 1;
                }

                pending_gap = 0;
                start_idx = i;
                same = 0;
                gap = 0;
                end_idx = i;
                started = false;
            }
        }

        end_idx = b;
        if (pending_gap == 1) {
            end_idx -= 1;
        }

        if (same > 1) {
            patterns[nb_pattern] = .{
                .same = same,
                .gap = gap,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .gap_idx = gap_idx,
            };
            nb_pattern += 1;
        }

        return nb_pattern;
    }

    fn analyzeThreats(self: *Evaluator, seq: []const board.Cell, player: board.Cell) ![]Threat2 {
        const opponent = if (player == board.Cell.own) board.Cell.opponent else board.Cell.own;
        const left_blocked = seq[0] == opponent;
        const right_blocked = seq[seq.len - 1] == opponent;

        var threats = std.ArrayList(Threat2).init(self.allocator);

        if (left_blocked and right_blocked) {
            if (seq.len - 2 < 5) {
                try threats.append(Threat2.none);
            } else {
                const start_idx = 1;
                const end_idx = seq.len - 2;
                var patterns: [8]Pattern = undefined;
                const nb_pattern = findPatterns(seq, start_idx, end_idx, &patterns, player);

                var i: u32 = 0;
                while (i < nb_pattern) : (i += 1) {
                    const sequence = Sequence.resolve(patterns[i].same, patterns[i].gap, patterns[i].gap_idx);
                    const blocked = patterns[i].start_idx == start_idx or patterns[i].end_idx == end_idx;
                    const head_type: Head = if (blocked) Head.blocked else Head.straight;
                    try threats.append(sequence.toThreatType(head_type));
                }
            }
        } else if (left_blocked) {
            var patterns: [8]Pattern = undefined;
            const nb_pattern = findPatterns(seq, 1, seq.len - 1, &patterns, player);

            var i: u32 = 0;
            while (i < nb_pattern) : (i += 1) {
                const sequence = Sequence.resolve(patterns[i].same, patterns[i].gap, patterns[i].gap_idx);
                const head_type: Head = if (patterns[i].start_idx == 1) Head.blocked else Head.straight;
                try threats.append(sequence.toThreatType(head_type));
            }
        } else if (right_blocked) {
            var patterns: [8]Pattern = undefined;
            const nb_pattern = findPatterns(seq, 0, seq.len - 2, &patterns, player);

            var i: u32 = 0;
            while (i < nb_pattern) : (i += 1) {
                const sequence = Sequence.resolve(patterns[i].same, patterns[i].gap, patterns[i].gap_idx);
                const head_type: Head = if (patterns[i].end_idx == seq.len - 2) Head.blocked else Head.straight;
                try threats.append(sequence.toThreatType(head_type));
            }
        } else {
            var patterns: [8]Pattern = undefined;
            const nb_pattern = findPatterns(seq, 0, seq.len - 1, &patterns, player);

            var i: u32 = 0;
            while (i < nb_pattern) : (i += 1) {
                const sequence = Sequence.resolve(patterns[i].same, patterns[i].gap, patterns[i].gap_idx);
                try threats.append(sequence.toThreatType(Head.straight));
            }
        }

        return threats.toOwnedSlice();
    }
};

// Represents a potential move with its position and evaluation score
pub const Threat = struct {
    row: u16,
    col: u16,
    score: i64,
};

// Comparison function for sorting threats by score in descending order
fn compareThreatsByScore(_: void, a: Threat, b: Threat) bool {
    return b.score < a.score;
}

// Finds all potential threats on the board
pub fn findThreats(map: []board.Cell, threats: []Threat, size: u32) u16 {
    var nb_threats: u16 = 0;

    // Scan entire board for empty cells
    var row: u16 = 0;
    while (row < size) : (row += 1) {
        var col: u16 = 0;
        const row_offset = row * size;
        while (col < size) : (col += 1) {
            const index = row_offset + col;
            if (map[index] == board.Cell.empty) {
                const w_score = evaluator.evaluate(board.game_board, board.Cell.own, .{ .x = @intCast(col), .y = @intCast(row) }) catch |err| {
                    std.debug.print("Error: {}\n", .{err});
                    return 0;
                };
                const b_score = evaluator.evaluate(board.game_board, board.Cell.opponent, .{ .x = @intCast(col), .y = @intCast(row) }) catch |err| {
                    std.debug.print("Error: {}\n", .{err});
                    return 0;
                };
                const score: i64 = w_score + b_score;
                if (score > 0) {
                    threats[nb_threats] = .{ .row = row, .col = col, .score = score };
                    nb_threats += 1;
                }
            }
        }
    }

    // Sort threats by score
    std.sort.block(Threat, threats[0..nb_threats], {}, compareThreatsByScore);
    return nb_threats;
}

// Generates a heuristic score by summing up threats of white
// and black pieces on the board. strategy is based on zero-sum principle.
fn evaluatePosition(map: []board.Cell, comptime size: u32, player: board.Cell) i64 {
    var score_sum: i64 = 0;

    // Evaluate all pieces on the board
    comptime var row: u16 = 0;
    inline while (row < size) : (row += 1) {
        comptime var col: u16 = 0;
        const row_offset = comptime row * size;
        inline while (col < size) : (col += 1) {
            const cell = map[row_offset + col];
            if (cell != board.Cell.empty) {
                // Add score for own pieces, subtract for opponent's
                const score = evaluator.evaluate(board.game_board, cell, .{ .x = @intCast(col), .y = @intCast(row) }) catch |err| {
                    std.debug.print("Error: {}\n", .{err});
                    return 0;
                } * if (cell == board.Cell.opponent) 1 else -1;
                score_sum += score;
            }
        }
    }
    return if (player == board.Cell.opponent) score_sum else -score_sum;
}

fn getHeuristicVal(map: []board.Cell, zobrist_table: *zobrist.ZobristTable, comptime size: u32, player: board.Cell) i64 {
    if (zobrist_table.lookupHeuristic()) |cached_heuristic| {
        return cached_heuristic;
    }
    const score = evaluatePosition(map, size, player);
    zobrist_table.storeHeuristic(score);

    return score;
}

// Maximizing player's turn
fn maximize(map: []board.Cell,
    zobrist_table: *zobrist.ZobristTable,
    depth: u8,
    alpha_in: i64,
    beta_in: i64,
    comptime size: u32,
    threats: []Threat) ?Threat
{
    var bestMove: ?Threat = null;
    var alpha = alpha_in;
    var i: u16 = 0;

    while (i < threats.len) : (i += 1) {
        const index = threats[i].row * size + threats[i].col;

        map[index] = board.Cell.own;
        zobrist_table.updateHash(board.Cell.own, threats[i].row, threats[i].col);

        const result = minimax(map, zobrist_table, depth - 1, false, alpha, beta_in, size);

        map[index] = board.Cell.empty;
        zobrist_table.updateHash(board.Cell.own, threats[i].row, threats[i].col); // XOR again to undo

        if (result) |move| {
            const score = move.score;

            if (bestMove == null or score > bestMove.?.score) {
                bestMove = threats[i];
                bestMove.?.score = score;
                if (score >= Evaluator.win) {
                    break;
                }
            }

            alpha = @max(alpha, score);

            if (beta_in <= alpha) {
                bestMove.?.score = alpha;
                cumulative_cut_depth += depth;
                alpha_cut += 1;
                break; // Beta cutoff
            }
        }
    }
    if (bestMove) |move| {
        if (move.score < -Evaluator.win) { // TODO: is this useful?
            const defensiveMove = .{ .row = threats[0].row, .col = threats[0].col, .score = move.score };
            zobrist_table.storePosition(depth, defensiveMove);
            return defensiveMove;
        }

        zobrist_table.storePosition(depth, move);
        return move;
    }
    return null;
}

// Minimizing player's turn
fn minimize(map: []board.Cell,
    zobrist_table: *zobrist.ZobristTable,
    depth: u8,
    alpha_in: i64,
    beta_in: i64,
    comptime size: u32,
    threats: []Threat) ?Threat
{
    var beta = beta_in;

    if (threats.len == 1) { // TODO: is this useful?
        var move = threats[0];
        const index = move.row * size + move.col;

        map[index] = board.Cell.opponent;
        zobrist_table.updateHash(board.Cell.opponent, move.row, move.col);

        const score = minimax(map, zobrist_table, depth - 1, true, alpha_in, beta_in, comptime size);
        if (score) |s| {
            map[index] = board.Cell.empty;
            zobrist_table.updateHash(board.Cell.opponent, move.row, move.col); // XOR again to undo
            move.score = s.score;
            return move;
        }
        map[index] = board.Cell.empty;
        zobrist_table.updateHash(board.Cell.opponent, move.row, move.col); // XOR again to undo
        return null;
    }

    var bestMove: ?Threat = null;
    var i: u16 = 0;

    while (i < threats.len) : (i += 1) {
        const index = threats[i].row * size + threats[i].col;

        map[index] = board.Cell.opponent;
        zobrist_table.updateHash(board.Cell.opponent, threats[i].row, threats[i].col);

        const result = minimax(map, zobrist_table, depth - 1, true, alpha_in, beta, size);

        map[index] = board.Cell.empty;
        zobrist_table.updateHash(board.Cell.opponent, threats[i].row, threats[i].col); // XOR again to undo

        if (result) |move| {
            const score = move.score;

            if (bestMove == null or score < bestMove.?.score) {
                bestMove = threats[i];
                bestMove.?.score = score;
                if (score <= -Evaluator.win) {
                    break;
                }
            }

            beta = @min(beta, score);

            if (beta <= alpha_in) {
                bestMove.?.score = beta;
                cumulative_cut_depth += depth;
                beta_cut += 1;
                break; // Alpha cutoff
            }
        }
    }
    if (bestMove) |move| {
        zobrist_table.storePosition(depth, move);
        return move;
    }
    return null;
}

// Minimax algorithm with alpha-beta pruning and transposition table
pub fn minimax(map: []board.Cell,
    zobrist_table: *zobrist.ZobristTable,
    depth: u8,
    comptime isMaximizing: bool,
    alpha_in: i64,
    beta_in: i64,
    comptime size: u32) ?Threat
{
    node += 1;
    // Check transposition table
    if (zobrist_table.lookupPosition(depth)) |cached_move| {
        return cached_move;
    }

    const player = comptime if (isMaximizing) board.Cell.own else board.Cell.opponent;

    const score = getHeuristicVal(map, zobrist_table, size, player);

    // Base case: evaluate position when depth is reached
    if (depth == 0 or score >= Evaluator.win or score <= -Evaluator.win) {
        return .{ .row = 0, .col = 0, .score = score };
    }

    var threats: [size * size]Threat = undefined;
    const nb_threats = @min(4, findThreats(map, &threats, size)); // Breadth = 4

    if (isMaximizing) {
        // Maximizing player's turn
        return maximize(map, zobrist_table, depth, alpha_in, beta_in, size, threats[0..nb_threats]);
    } else {
        // Minimizing player's turn
        return minimize(map, zobrist_table, depth, alpha_in, beta_in, size, threats[0..nb_threats]);
    }
}

// Finds the best move for the AI using minimax algorithm, zobrist transposition table
pub fn findBestMove(comptime size: comptime_int) Threat {
    const current_board = &board.game_board;
    evaluator = Evaluator.init(Allocator) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return Threat{ .row = 0, .col = 0, .score = 0 };
    };
    defer evaluator.deinit();
    node = 0;
    alpha_cut = 0;
    beta_cut = 0;
    cumulative_cut_depth = 0;

    _ = zobrist.ztable.calculateHash(current_board.map);

    if (minimax(current_board.map, &zobrist.ztable, 5, true, std.math.minInt(i64), std.math.maxInt(i64), comptime size)) |move| {
        const avg_cut_depth: f32 = @as(f32, @floatFromInt(cumulative_cut_depth)) / @as(f32, @floatFromInt(alpha_cut + beta_cut));
        std.debug.print("Alpha cut: {d}, Beta cut: {d}, Average cut depth: {}\n", .{alpha_cut, beta_cut, avg_cut_depth});
        std.debug.print("Node explored: {d}\n", .{node});
        return move;
    } else { // The computer is loosing
        const cell = board.findRandomValidCell(current_board.*, main.random) catch {
            return Threat{ .row = 0, .col = 0, .score = 0 };
        };
        return Threat{ .row = @intCast(cell.y), .col = @intCast(cell.x), .score = 0 };
    }
}

pub fn getBotMove5() Threat {
    return findBestMove(5);
}
pub fn getBotMove6() Threat {
    return findBestMove(6);
}
pub fn getBotMove7() Threat {
    return findBestMove(7);
}
pub fn getBotMove8() Threat {
    return findBestMove(8);
}
pub fn getBotMove9() Threat {
    return findBestMove(9);
}
pub fn getBotMove10() Threat {
    return findBestMove(10);
}
pub fn getBotMove11() Threat {
    return findBestMove(11);
}
pub fn getBotMove12() Threat {
    return findBestMove(12);
}
pub fn getBotMove13() Threat {
    return findBestMove(13);
}
pub fn getBotMove14() Threat {
    return findBestMove(14);
}
pub fn getBotMove15() Threat {
    return findBestMove(15);
}
pub fn getBotMove16() Threat {
    return findBestMove(16);
}
pub fn getBotMove17() Threat {
    return findBestMove(17);
}
pub fn getBotMove18() Threat {
    return findBestMove(18);
}
pub fn getBotMove19() Threat {
    return findBestMove(19);
}
pub fn getBotMove20() Threat {
    return findBestMove(20);
}
