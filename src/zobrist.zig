const std = @import("std");
const board = @import("board.zig");
const main = @import("main.zig");
const ai = @import("ai.zig");

pub var ztable: ZobristTable = undefined;

pub const ZobristTable = struct {
    // Constants
    pub const Key = u64;
    pub const TableSize = 1024 * 1024; // 1M entries

    pub const Flag = enum {
        EXACT,
        LOWERBOUND,
        UPPERBOUND,
    };

    pub const Entry = struct {
        key: Key,
        depth: u8,
        threat: ai.Threat,
    };

    // Member variables
    size: u32,
    transposition_table: []?Entry,
    heuristics_table: []?i64,
    zobrist_table: [2][20][20]Key,
    current_hash: Key,

    // Constructor
    pub fn init(board_size: u32, random: std.Random, allocator: std.mem.Allocator) !ZobristTable {
        var self = ZobristTable{
            .size = board_size,
            .transposition_table = try allocator.alloc(?Entry, TableSize),
            .heuristics_table = try allocator.alloc(?i64, TableSize),
            .zobrist_table = undefined,
            .current_hash = 0,
        };
        @memset(self.transposition_table, null);
        @memset(self.heuristics_table, null);

        // Initialize random values for each position and piece
        for (0..2) |piece| {
            for (0..board_size) |row| {
                for (0..board_size) |col| {
                    self.zobrist_table[piece][row][col] = random.int(Key);
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *ZobristTable, allocator: std.mem.Allocator) void {
        allocator.free(self.transposition_table);
        allocator.free(self.heuristics_table);
    }

    // Calculate initial hash for a given board position
    pub fn calculateHash(self: *ZobristTable, map: []const board.Cell) Key {
        var hash: Key = 0;
        var row: u32 = 0;
        while (row < self.size) : (row += 1) {
            var col: u32 = 0;
            while (col < self.size) : (col += 1) {
                const cell = map[row * self.size + col];
                if (cell != board.Cell.empty) {
                    const piece_index: u32 = if (cell == board.Cell.own) 0 else 1;
                    hash ^= self.zobrist_table[piece_index][row][col];
                }
            }
        }
        self.current_hash = hash;
        return hash;
    }

    // Update hash for a move
    pub fn updateHash(self: *ZobristTable, piece: board.Cell, row: u32, col: u32) void {
        if (piece != board.Cell.empty) {
            const piece_index: u32 = if (piece == board.Cell.own) 0 else 1;
            self.current_hash ^= self.zobrist_table[piece_index][row][col];
        }
    }

    pub fn storeHeuristic(self: *ZobristTable, score: i64) void {
        const index = self.current_hash % TableSize;
        self.heuristics_table[index] = score;
    }

    // Store position in transposition table
    pub fn storePosition(self: *ZobristTable, depth: u8, move: ai.Threat) void {
        const index = self.current_hash % TableSize;
        self.transposition_table[index] = Entry{
            .key = self.current_hash,
            .depth = depth,
            .threat = move,
        };
    }

    pub fn lookupHeuristic(self: *ZobristTable) ?i64 {
        const index = self.current_hash % TableSize;
        const entry = self.heuristics_table[index];

        if (entry) |e| {
            return e;
        }
        return null;
    }

    // Lookup position in transposition table
    pub fn lookupPosition(self: *ZobristTable, depth: u8) ?ai.Threat {
        const index = self.current_hash % TableSize;
        const entry = self.transposition_table[index];

        if (entry) |e| {
            if (e.depth >= depth) {
                // switch (e.flag) {
                //     .EXACT => return e.score,
                //     .LOWERBOUND => {
                //         if (e.score >= beta) return beta;
                //     },
                //     .UPPERBOUND => {
                //         if (e.score <= alpha) return alpha;
                //     },
                // }
                return e.threat;
            }
        }
        return null;
    }

    // Clear the transposition table
    pub fn clear(self: *ZobristTable) void {
        for (self.transposition_table) |*entry| {
            entry.* = null;
        }
        self.current_hash = 0;
    }

    // Get current hash value
    pub fn getCurrentHash(self: ZobristTable) Key {
        return self.current_hash;
    }
};
