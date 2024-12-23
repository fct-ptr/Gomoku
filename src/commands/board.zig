const std = @import("std");
const board = @import("../board.zig");
const io = @import("../io.zig");
const message = @import("../message.zig");
const main = @import("../main.zig");
const game = @import("../game.zig");
const ai = @import("../ai.zig");
const turn = @import("turn.zig");
const zobrist = @import("../zobrist.zig");


var stdin = std.io.getStdIn().reader().any();

const ParseBoardLineError = error {
/// Occur when not enough values are provided into the line (ex: 2/3).
    NotEnoughValues,
};

/// Function used to obtain values from a board line.
/// Ex: "10,10,1"
/// - Parameters:
///     - line: The line to parse.
///     - parsed_values: A pointer on a array of 3 optional u32.
///     - writer: The writer used for logging message.
fn getValuesFromBoardLine(
    line: []const u8,
    parsed_values: *[3]?u32,
) !void {
    var it = std.mem.splitScalar(u8, line, ',');
    for (0..3) |i| {
        const word = it.next();
        if (word == null) {
            parsed_values[i] = null;
            return ParseBoardLineError.NotEnoughValues;
        }
        parsed_values[i] = std.fmt.parseInt(u32, word.?, 10)
            catch |err| return err;
    }
}

fn handleBoard (
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter
) !void {
    var read_buffer = try std.BoundedArray(u8, 256).init(0);
    var parsed_values: [3]?u32 = undefined;

    while (true) {
        try io.readLineIntoBuffer(reader, &read_buffer, writer);
        if (std.ascii.startsWithIgnoreCase(read_buffer.slice(), "DONE")) {
            // The command is terminated.
            break;
        }
        // Clear the parsed_values array.
        @memset(&parsed_values, null);
        // Parse values and sets them into parsed_values array.
        getValuesFromBoardLine(
            read_buffer.slice(),
            &parsed_values
        ) catch |err| {
            return try message.sendLogF(
                .ERROR,
                "error during board command parsing: {}",
                .{err},
                writer
            );
        };
        // Verify the cell type.
        if (!board.Cell.isAvailableCell(parsed_values[2].?)) {
            return try message.sendLogF(
                .ERROR,
                "the cell type is not recognized: {}",
                .{parsed_values[2].?},
                writer
            );
        }
        // Verify the cell coordinates.
        if (board.game_board.isCoordinatesOutside(
            parsed_values[0].?,
            parsed_values[1].?
        )) {
            return try message.sendLogF(
                .ERROR,
                "error the coordinates are outside the map: x:{} y:{} "
                    ++ "map_width:{} map_height:{}",
                .{parsed_values[0].?, parsed_values[1].?,
                    board.game_board.width, board.game_board.height},
                writer
            );
        }
        // Finally set the cell on the board.
        board.game_board.setCellByCoordinates(
            parsed_values[0].?,
            parsed_values[1].?,
            @enumFromInt(parsed_values[2].?)
        );
    }
    // Send coordinates.
    const ai_move = turn.AIPlay();

    // const ai_move = try AIPlayMCTS();

    try message.sendMessageF("{d},{d}", .{ai_move[0], ai_move[1]}, writer);
}

pub fn handle(_: []const u8, writer: std.io.AnyWriter) !void {
    return handleBoard(stdin, writer);
}

test "handle valid input" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    message.init(std.testing.allocator);

    // Setup a test reader with valid input
    var fbs = std.io.fixedBufferStream(
        "1,1,1\n2,2,2\nDONE\n"
    );

    // Initialize the board.
    board.game_board = board.Board.init(
        testing.allocator,
        5, 5
    ) catch |err| { return err; };
    defer board.game_board.deinit(testing.allocator);

    var real_prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    main.random = real_prng.random();

    zobrist.ztable = try zobrist.ZobristTable.init(
        5,
        main.random,
        std.testing.allocator
    );
    defer zobrist.ztable.deinit(std.testing.allocator);

    stdin = fbs.reader().any();
    try handle("", buffer.writer().any());

    // Verify the board state
    try testing.expectEqual(board.Cell.own, board.game_board.getCellByCoordinates(1, 1));
    try testing.expectEqual(board.Cell.opponent, board.game_board.getCellByCoordinates(2, 2));
}

test "handleBoard valid input" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Setup a test reader with valid input
    var fbs = std.io.fixedBufferStream(
        "1,1,1\n2,2,2\nDONE\n"
    );

    // Initialize the board.
    board.game_board = board.Board.init(
        testing.allocator,
        5, 5
    ) catch |err| { return err; };
    defer board.game_board.deinit(testing.allocator);

    var real_prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    main.random = real_prng.random();

    zobrist.ztable = try zobrist.ZobristTable.init(
        5,
        main.random,
        std.testing.allocator
    );
    defer zobrist.ztable.deinit(std.testing.allocator);

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    // Verify the board state
    try testing.expectEqual(board.Cell.own, board.game_board.getCellByCoordinates(1, 1));
    try testing.expectEqual(board.Cell.opponent, board.game_board.getCellByCoordinates(2, 2));
}

test "handleBoard invalid coordinates" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Setup a test reader with coordinates outside board
    var fbs = std.io.fixedBufferStream(
        "999,999,1\nDONE\n"
    );

    // Initialize the board.
    board.game_board = board.Board.init(
        testing.allocator,
        5, 5
    ) catch |err| { return err; };
    defer board.game_board.deinit(testing.allocator);

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    // Verify error message was written
    try testing.expectEqualStrings("ERROR error the coordinates are outside the map: x:999 y:999 map_width:5 map_height:5\n",
        buffer.items);
}

test "handleBoard invalid cell type" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Setup a test reader with invalid cell type
    var fbs = std.io.fixedBufferStream(
        "1,1,99\nDONE\n"
    );

    // Initialize the board.
    board.game_board = board.Board.init(
        testing.allocator,
        5, 5
    ) catch |err| { return err; };
    defer board.game_board.deinit(testing.allocator);

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    // Verify error message was written
    try testing.expect(std.mem.eql(u8, buffer.items,
        "ERROR the cell type is not recognized: 99\n"
    ));
}

test "handleBoard parse error not enough values" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Setup a test reader with invalid format
    var fbs = std.io.fixedBufferStream(
        "1,1\nDONE\n"
    );

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    // Verify error message was written
    try testing.expect(std.mem.eql(u8, buffer.items,
        "ERROR error during board command parsing: error.NotEnoughValues\n"
    ));
}

test "handleBoard parse error wrong type" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Setup a test reader with invalid format
    var fbs = std.io.fixedBufferStream(
        "1,1,test\nDONE\n"
    );

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    // Verify error message was written
    try testing.expect(std.mem.eql(u8, buffer.items,
        "ERROR error during board command parsing: error.InvalidCharacter\n"
    ));
}

test "handleBoard early DONE" {
    const testing = std.testing;
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Initialize the board.
    board.game_board = board.Board.init(std.testing.allocator, 5, 5) catch |err| { return err; };
    defer board.game_board.deinit(std.testing.allocator);

    // Setup a test reader with immediate DONE
    var fbs = std.io.fixedBufferStream("DONE\n");

    var real_prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    main.random = real_prng.random();

    zobrist.ztable = try zobrist.ZobristTable.init(
        5,
        main.random,
        std.testing.allocator
    );
    defer zobrist.ztable.deinit(std.testing.allocator);

    try handleBoard(fbs.reader().any(), buffer.writer().any());

    const comma_pos = std.mem.indexOf(u8, buffer.items, ",");
    try std.testing.expect(comma_pos != null);

    const x = try std.fmt.parseUnsigned(
        u32,
        buffer.items[0..comma_pos.?],
        10
    );
    const y = try std.fmt.parseUnsigned(
        u32,
        buffer.items[comma_pos.? + 1..buffer.items.len - 1],
        10
    );
    try std.testing.expectEqual(u32, @TypeOf(x));
    try std.testing.expectEqual(u32, @TypeOf(y));
    try std.testing.expectEqual(board.Cell.own, board.game_board.getCellByCoordinates(x, y));
}

test "getValuesFromBoardLine valid input" {
    const testing = std.testing;
    var parsed_values: [3]?u32 = undefined;
    try getValuesFromBoardLine("10,20,1", &parsed_values);

    try testing.expectEqual(@as(?u32, 10), parsed_values[0]);
    try testing.expectEqual(@as(?u32, 20), parsed_values[1]);
    try testing.expectEqual(@as(?u32, 1), parsed_values[2]);
}

test "getValuesFromBoardLine not enough values" {
    const testing = std.testing;
    var parsed_values: [3]?u32 = undefined;
    try testing.expectError(
        ParseBoardLineError.NotEnoughValues,
        getValuesFromBoardLine("10,20", &parsed_values)
    );
}

test "getValuesFromBoardLine invalid number" {
    const testing = std.testing;
    var parsed_values: [3]?u32 = undefined;
    try testing.expectError(
        error.InvalidCharacter,
        getValuesFromBoardLine("10,abc,1", &parsed_values)
    );
}

test "Cell.isAvailableCell valid values" {
    const testing = std.testing;
    try testing.expect(board.Cell.isAvailableCell(1));
    try testing.expect(board.Cell.isAvailableCell(2));
    try testing.expect(board.Cell.isAvailableCell(3));
}

test "Cell.isAvailableCell invalid values" {
    const testing = std.testing;
    try testing.expect(!board.Cell.isAvailableCell(0));
    try testing.expect(!board.Cell.isAvailableCell(4));
}

test "Board initialization and deinitialization" {
    const testing = std.testing;
    const height: u32 = 10;
    const width: u32 = 10;

    var test_board = try board.Board.init(
        testing.allocator,
        height,
        width
    );
    defer test_board.deinit(testing.allocator);

    try testing.expectEqual(height, test_board.height);
    try testing.expectEqual(width, test_board.width);
    try testing.expectEqual(height * width, test_board.map.len);
}

test "findRandomValidCell with empty board" {
    const testing = std.testing;
    const height: u32 = 10;
    const width: u32 = 10;

    var test_board = try board.Board.init(
        testing.allocator,
        height,
        width
    );
    defer test_board.deinit(testing.allocator);

    var real_prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const coords = try board.findRandomValidCell(test_board, real_prng.random());

    try testing.expect(coords.x < width);
    try testing.expect(coords.y < height);
}

test "findRandomValidCell with full board" {
    const testing = std.testing;
    const height: u32 = 5;
    const width: u32 = 5;

    var test_board = try board.Board.init(
        testing.allocator,
        height,
        width
    );
    defer test_board.deinit(testing.allocator);

    // Fill the board
    for (0..height) |y| {
        for (0..width) |x| {
            test_board.setCellByCoordinates(
                @intCast(x),
                @intCast(y),
                board.Cell.own
            );
        }
    }

    var prng = std.Random.DefaultPrng.init(42);
    try testing.expectError(
        error.NoEmptyCells,
        board.findRandomValidCell(test_board, prng.random())
    );
}

test "Board move history" {
    const testing = std.testing;
    const height: u32 = 5;
    const width: u32 = 5;

    var test_board = try board.Board.init(
        testing.allocator,
        height,
        width
    );
    defer test_board.deinit(testing.allocator);

    test_board.setCellByCoordinates(1, 1, board.Cell.own);
    test_board.setCellByCoordinates(2, 2, board.Cell.opponent);
}
