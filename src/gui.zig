const std = @import("std");
const capy = @import("capy");
const board = @import("board.zig");
const start = @import("commands/start.zig");
const turn = @import("commands/turn.zig");

// Theme configuration struct
const Theme = struct {
    background_color: [3]f32,
    grid_color: [3]f32,
    own_stone_color: [3]f32,
    opponent_stone_color: [3]f32,
    winning_line_color: [3]f32,
};

var current_theme = Theme{
    .background_color = .{ 0.862745098039, 0.701960784314, 0.360784313725 },
    .grid_color = .{ 0.0, 0.0, 0.0 },
    .own_stone_color = .{ 1.0, 1.0, 1.0 },
    .opponent_stone_color = .{ 0.0, 0.0, 0.0 },
    .winning_line_color = .{ 1.0, 0.0, 0.0 },
};

// Add player color choice
var player_plays_white: bool = true;
var color_chosen = false;
var dialog: capy.Window = undefined;

const themes = struct {
    const classic = Theme{
        .background_color = .{ 0.862745098039, 0.701960784314, 0.360784313725 },
        .grid_color = .{ 0.0, 0.0, 0.0 },
        .own_stone_color = .{ 1.0, 1.0, 1.0 },
        .opponent_stone_color = .{ 0.0, 0.0, 0.0 },
        .winning_line_color = .{ 1.0, 0.0, 0.0 },
    };

    const dark = Theme{
        .background_color = .{ 0.2, 0.2, 0.2 },
        .grid_color = .{ 0.8, 0.8, 0.8 },
        .own_stone_color = .{ 0.9, 0.9, 0.9 },
        .opponent_stone_color = .{ 0.1, 0.1, 0.1 },
        .winning_line_color = .{ 1.0, 0.3, 0.3 },
    };

    const nature = Theme{
        .background_color = .{ 0.4, 0.6, 0.3 },
        .grid_color = .{ 0.2, 0.3, 0.1 },
        .own_stone_color = .{ 0.9, 0.9, 0.8 },
        .opponent_stone_color = .{ 0.2, 0.2, 0.1 },
        .winning_line_color = .{ 0.8, 0.3, 0.2 },
    };
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var grid_info: struct {
    start_x: i32 = 0,
    start_y: i32 = 0,
    cell_size: i32 = 0,
} = .{};

var game_won: bool = false;

var canva: *capy.Canvas = undefined;

var start_command: []u8 = undefined;


pub fn run_gui() !void {
    try capy.init();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    var size: [2]u8 = .{'1', '5'};

    if (args.len > 1 and std.mem.eql(u8, "--size", args[1])) {
        const s = std.fmt.parseUnsigned(u8, args[2], 10) catch |err| {
            std.debug.print("Invalid size: {}\n", .{err});
            return;
        };
        if (s > 32 or s < 5) {
            std.debug.print("Invalid size: {}\n", .{s});
            return;
        }
        size[0] = args[2][0];
        size[1] = args[2][1];
    }

    var start_buf = [_]u8{0} ** 10;
    start_command = try std.fmt.bufPrint(&start_buf, "START {s}", .{size});

    try start.handle(start_command, std.io.getStdOut().writer().any());

    var window = try capy.Window.init();
    canva = capy.canvas(.{
        .preferredSize = capy.Size.init(500, 500),
        .ondraw = @as(*const fn (*anyopaque, *capy.DrawContext) anyerror!void, @ptrCast(&onDraw)),
        .name = "zomoku-canvas",
    });
    try canva.addMouseButtonHandler(&onCellClicked);

    try window.set(capy.column(.{ .spacing = 10 }, .{
        capy.row(.{ .spacing = 10 }, .{
            capy.button(.{ .label = "RESET", .onclick = resetButton }),
            capy.button(.{ .label = "Classic Theme", .onclick = setClassicTheme }),
            capy.button(.{ .label = "Dark Theme", .onclick = setDarkTheme }),
            capy.button(.{ .label = "Nature Theme", .onclick = setNatureTheme }),
        }),
        capy.expanded(
            capy.row(.{ .spacing = 10 }, .{
                capy.column(.{}, .{}),
                capy.expanded(
                    canva,
                ),
                capy.column(.{}, .{}),
            }),
        ),
        capy.row(.{}, .{}),
    }));

    window.setTitle("Zomoku");
    window.setPreferredSize(500, 500);

    // Create and show color choice dialog
    try showColorChoiceDialog();

    window.show();
    capy.runEventLoop();
}

fn showColorChoiceDialog() !void {
    dialog = try capy.Window.init();
    try dialog.set(
        capy.column(.{ .spacing = 20 }, .{
            capy.label(.{ .text = "Choose your stone color:" }),
            capy.row(.{ .spacing = 10 }, .{
                capy.button(.{
                    .label = "Play as White",
                    .onclick = selectWhiteAndClose
                }),
                capy.button(.{
                    .label = "Play as Black",
                    .onclick = selectBlackAndClose
                }),
            }),
        }),
    );

    dialog.setTitle("Color Selection");
    dialog.setPreferredSize(250, 150);
    dialog.show();
}

fn selectWhiteAndClose(_: *anyopaque) !void {
    player_plays_white = true;
    color_chosen = true;
    dialog.close();

    // AI plays first move when player chooses white
    const ai_move = turn.AIPlay();
    std.debug.print("AI played on cell ({d}, {d})\n", .{ai_move[0], ai_move[1]});
    if (try board.game_board.addWinningLine(ai_move[0], ai_move[1]))
        game_won = true;
    try canva.requestDraw();
}

fn selectBlackAndClose(_: *anyopaque) !void {
    player_plays_white = false;
    color_chosen = true;
    dialog.close();
    try canva.requestDraw();
}


fn onCellClicked(widget: *capy.Canvas, button: capy.MouseButton, pressed: bool, x: i32, y: i32) !void {
    if (!color_chosen) return;

    if (button == .Left and pressed and !game_won) {
        // Calculate which cell was clicked
        const relative_x = x - grid_info.start_x;
        const relative_y = y - grid_info.start_y;

        // Check if click is within grid bounds
        if (relative_x >= 0 and relative_y >= 0) {
            const col = @divFloor(relative_x, grid_info.cell_size);
            const row = @divFloor(relative_y, grid_info.cell_size);

            if (col >= 0 and col < board.game_board.width and
                row >= 0 and row < board.game_board.height) {
                std.debug.print("Clicked on cell ({d}, {d})\n", .{col, row});

                turn.setEnnemyStone(@as(u32, @intCast(col)), @as(u32, @intCast(row))) catch |err| {
                    switch (err) {
                        turn.PlayError.OUTSIDE => std.debug.print("Coordinates are outside the board\n", .{}),
                        turn.PlayError.OCCUPIED => std.debug.print("Cell is not empty\n", .{}),
                    }
                    return;
                };

                if (try board.game_board.addWinningLine(@as(u32, @intCast(col)), @as(u32, @intCast(row)))) {
                    // Request redraw to update the board
                    try widget.requestDraw();
                    game_won = true;
                    return;
                } else {
                    // Request redraw to update the board
                    try widget.requestDraw();
                }

                const ai_move = turn.AIPlay();
                std.debug.print("AI played on cell ({d}, {d})\n", .{ai_move[0], ai_move[1]});

                if (try board.game_board.addWinningLine(ai_move[0], ai_move[1]))
                    game_won = true;

                // Request redraw to update the board
                try widget.requestDraw();
            }
        }
    }
}

fn setClassicTheme(_: *anyopaque) !void {
    current_theme = themes.classic;
    try canva.requestDraw();
}

fn setDarkTheme(_: *anyopaque) !void {
    current_theme = themes.dark;
    try canva.requestDraw();
}

fn setNatureTheme(_: *anyopaque) !void {
    current_theme = themes.nature;
    try canva.requestDraw();
}

fn resetButton(_: *anyopaque) !void {
    try start.handle(start_command, std.io.getStdOut().writer().any());
    game_won = false;
    color_chosen = false;
    try showColorChoiceDialog();
    try canva.requestDraw();
}

fn onDraw(widget: *capy.Canvas, ctx: *capy.DrawContext) !void {
    std.debug.print("Drawing board\n", .{});
    const width = @as(i32, @intCast(widget.getWidth()));
    const height = @as(i32, @intCast(widget.getHeight()));

    // Draw background
    ctx.setColor(
        current_theme.background_color[0],
        current_theme.background_color[1],
        current_theme.background_color[2],
    );
    ctx.rectangle(0, 0, @as(u32, @intCast(width)), @as(u32, @intCast(height)));
    ctx.fill();

    // Calculate usable area for the grid
    const min_dimension = @min(width, height);
    const margin: i32 = @divFloor(min_dimension, 50);
    const grid_size = min_dimension - 2 * margin;
    const cell_size = @divFloor(grid_size, @as(i32, @intCast(board.game_board.width)));

    const actual_grid_size = cell_size * @as(i32, @intCast(board.game_board.width));
    const start_x = @divFloor(width - actual_grid_size, 2);
    const start_y = @divFloor(height - actual_grid_size, 2);

    grid_info.start_x = start_x;
    grid_info.start_y = start_y;
    grid_info.cell_size = cell_size;

    // Draw grid lines
    ctx.setColor(
        current_theme.grid_color[0],
        current_theme.grid_color[1],
        current_theme.grid_color[2],
    );

    // Vertical lines
    var col: u32 = 0;
    while (col <= board.game_board.width) : (col += 1) {
        const x = start_x + @as(i32, @intCast(col)) * cell_size;
        ctx.line(x, start_y, x, start_y + actual_grid_size);
        ctx.stroke();
    }

    // Horizontal lines
    var row: u32 = 0;
    while (row <= board.game_board.height) : (row += 1) {
        const y = start_y + @as(i32, @intCast(row)) * cell_size;
        ctx.line(start_x, y, start_x + actual_grid_size, y);
        ctx.stroke();
    }

    // Draw stones
    row = 0;
    while (row < board.game_board.height) : (row += 1) {
        col = 0;
        while (col < board.game_board.width) : (col += 1) {
            const cell = board.game_board.getCellByCoordinates(col, row);
            if (cell != .empty) {
                const center_x = start_x + @as(i32, @intCast(col)) * cell_size + @divFloor(cell_size, 2);
                const center_y = start_y + @as(i32, @intCast(row)) * cell_size + @divFloor(cell_size, 2);
                const stone_radius = @divFloor(cell_size * 4, 10); // Make stones slightly smaller than cell

                // Set color based on cell type
                switch (cell) {
                    .opponent => {
                        if (player_plays_white) {
                            ctx.setColor(
                                current_theme.own_stone_color[0],
                                current_theme.own_stone_color[1],
                                current_theme.own_stone_color[2],
                            );
                        } else {
                            ctx.setColor(
                                current_theme.opponent_stone_color[0],
                                current_theme.opponent_stone_color[1],
                                current_theme.opponent_stone_color[2],
                            );
                        }
                    },
                    .own => {
                        if (player_plays_white) {
                            ctx.setColor(
                                current_theme.opponent_stone_color[0],
                                current_theme.opponent_stone_color[1],
                                current_theme.opponent_stone_color[2],
                            );
                        } else {
                            ctx.setColor(
                                current_theme.own_stone_color[0],
                                current_theme.own_stone_color[1],
                                current_theme.own_stone_color[2],
                            );
                        }
                    },
                    .winning_line_or_forbidden => ctx.setColor(
                        current_theme.winning_line_color[0],
                        current_theme.winning_line_color[1],
                        current_theme.winning_line_color[2],
                    ),
                    .empty => continue,
                }

                ctx.ellipse(
                    center_x - stone_radius,
                    center_y - stone_radius,
                    @as(u32, @intCast(stone_radius * 2)),
                    @as(u32, @intCast(stone_radius * 2))
                );
                ctx.fill();
            }
        }
    }
}