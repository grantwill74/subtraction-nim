const std = @import("std");
const dbgPrint = std.debug.print;

// from zig reference, modified for base 10 only.
/// parse a slice into an unsigned integer.
/// errors: std.fmt.ParseIntError.Overlow, and (...).InvalidCharacter
/// if a string contains invalid characters *and* is too big, either
/// error could be returned.
fn parseDecU(buf: []const u8) std.fmt.ParseIntError!u64 {
    var acc: u64 = 0;

    for (buf) |c| {
        if (c < '0' or c > '9') { return error.InvalidCharacter; }

        var over = @mulWithOverflow(acc, 10);
        // if overflow bit is set
        if (over[1] == 1) { return error.Overflow; }

        const digit = c - '0';
        over = @addWithOverflow(over[0], digit);
        if (over[1] == 1) { return error.Overflow; }

        acc = over[0];
    }

    return acc;
}

fn bigNumStr() []const u8 {
    const maxval = std.math.maxInt(u64);
    const evenBigger: u65 = @as(u65, maxval) + 1;
    const slice =
        std.fmt.bufPrint(&u64_maxval_plus_1_buf, "{}", .{evenBigger}) 
        catch unreachable;
    return slice;
}

var u64_maxval_plus_1_buf: [32]u8 = undefined;
const u64_maxval_plus_1 = bigNumStr();

test parseDecU {
    const t = std.testing;

    try t.expectEqual(0, try parseDecU("0"));
    try t.expectEqual(1, try parseDecU("1"));
    try t.expectEqual(9, try parseDecU("9"));
    try t.expectEqual(10, try parseDecU("10"));
    try t.expectEqual(1234, try parseDecU("1234"));

    try t.expectEqual(error.InvalidCharacter, parseDecU("-123"));
    try t.expectEqual(error.InvalidCharacter, parseDecU("1u23"));
    try t.expectEqual(error.InvalidCharacter, parseDecU("12u3"));
    try t.expectEqual(error.InvalidCharacter, parseDecU("123u"));

    try t.expectEqual(error.Overflow, parseDecU(bigNumStr()));
}


/// prompt the user for an integer within the given range.
/// insist on a valid value: keep prompting over and over until
/// the user finally relents and enters the number followed by \\n.
/// start by printing the given prompt, then automatically shows
/// the inclusive range of acceptable values.
///
/// errors: error.streamTooLong, err..
fn promptIntInRangeInsist(
    reader: anytype,
    writer: anytype,
    prompt: []const u8,
    minNum: u64,
    maxNum: u64,
) !u64 {
    std.debug.assert(minNum <= maxNum);

    const maxDigits = 32;
    var buf: [maxDigits]u8 = [_]u8{0} ** maxDigits;
    var alloc = std.heap.FixedBufferAllocator.init(&buf);
    const arrAlloc = alloc.allocator();
    var arrList = try std.ArrayList(u8).initCapacity(arrAlloc, maxDigits);

    const num = while (true) {
        arrList.resize(0) catch unreachable;
        // print the prompt
        try writer.print("{s}[{}, {}]: ", .{ prompt, minNum, maxNum });

        reader.streamUntilDelimiter(arrList.writer(), '\n', maxDigits) 
        catch {
            try writer.print("not a valid integer in the given range.\n", .{});
            continue;
        };

        const parsed = parseDecU(arrList.items) 
        catch |e| switch (e) {
            error.Overflow => {
                const m = "number got too large before reaching the end.\n";
                try writer.print(m, .{});
                continue;
            },
            error.InvalidCharacter => {
                const m = "there is a non-digit symbol (0-9) in the number.\n";
                try writer.print(m, .{});
                continue;
            }
        };

        if (parsed < minNum or parsed > maxNum) {
            try writer.print(
                "number outside of range [{}, {}].\n",
                .{minNum, maxNum});
            continue;
        }

        break parsed;
    };
    
    return num;
}

const WhichPlayer = enum(u1) {
    Player = 1,
    Ai = 0,
};

const RulesError = error {
    MaxTakeIsZero,
    TargetScoreIsZero,
};

const Rules = struct {
    max_take: u8 = 2,
    points: u8 = 20,
    winner_takes_last: bool = true,

    fn init(
        max_take: u8,
        points: u8,
        winner_takes_last: bool,
    ) RulesError!Rules {
        if (max_take == 0) { return error.MaxTakeIsZero; }
        if (points == 0) { return error.TargetScoreIsZero; }

        return .{
            .max_take = max_take,
            .points = points,
            .winner_takes_last = winner_takes_last,
        };
    }

    test init {
        const t = std.testing;

        try t.expectError(error.MaxTakeIsZero, init(0, 20, true));
        try t.expectError(error.MaxTakeIsZero, init(0, 20, false));
        try t.expectError(error.TargetScoreIsZero, init(10, 0, true));
        try t.expectError(error.TargetScoreIsZero, init(10, 0, false));
        {
            const expected = Rules {
                .max_take = 3,
                .points = 10,
                .winner_takes_last = true,
            };
            try t.expectEqual(expected, init(3, 10, true));
        }
    }
};

const AiState = struct {
    first_goer: WhichPlayer,
    next_target: u8,
    // next target is always max_take + 1 + last_target
};

fn createAi(rules: Rules) AiState {
    std.debug.assert(rules.max_take > 0);
    std.debug.assert(rules.points > 0);

    if (rules.points == 1 and !rules.winner_takes_last) {
        return .{ .first_goer = .Player, .next_target = 1 };
    }

    // if loser takes last, then we want to take the one before last
    const actual_points = 
        if (rules.winner_takes_last)
            rules.points
        else 
            rules.points - 1;

    // if one can win in one turn, ai will want to go first
    if (rules.max_take >= actual_points) {
        return .{ .first_goer = .Ai, .next_target = 0};
    }

    // what number do we want to end our turn on at the end of the game, 
    // to guarantee we win after the opponent takes their turn?
    const last_target = rules.max_take + 1;
    const rem = (actual_points - last_target) % last_target;

    if (rem == 0) {
        return .{ 
            .first_goer = .Player, 
            .next_target = rules.points - rules.max_take - 1
        };
    }

    return .{ .first_goer = .Ai, .next_target = rules.points - rem };
}

test createAi {
    const t = std.testing;
    {
        const default_rules = Rules {};
        const default_expected = AiState {
            .first_goer = .Ai,
            .next_target = 18,
        };

        try t.expectEqual(default_expected, createAi(default_rules));
    }
    {
        const rule = Rules {
            .max_take = 3,
            .points = 20,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Player,
            .next_target = 16,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 4,
            .points = 20,
            .winner_takes_last = false,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 16,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 3,
            .points = 3,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 0,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 2,
            .points = 1,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 0,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 2,
            .points = 1,
            .winner_takes_last = false,
        };

        try t.expectEqual(.Player, createAi(rule).first_goer);
    }
    {
        const rule = Rules {
            .max_take = 1,
            .points = 10,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Player,
            .next_target = 8,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 1,
            .points = 10,
            .winner_takes_last = false,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 9,
        };

        try t.expectEqual(expected, createAi(rule));
    }
}

const MoveError = error {
    GameOver,
    TookZero,
    TookMoreThanRulesAllow,
    TookPastZero,
};

const NimGame = struct {
    rules: Rules,
    
    turn: u1,
    score_left: u8,

    fn init(rules: Rules) NimGame {
        return NimGame {
            .rules = rules,

            .turn = 0,
            .score_left = rules.points,
        };
    }

    fn makeMove(self: *NimGame, amount_to_take: u8) MoveError!void {
        if (self.gameWon()) { return error.GameOver; }
        if (amount_to_take == 0) { return error.TookZero; }
        if (amount_to_take > self.rules.max_take) 
            { return error.TookMoreThanRulesAllow; }
        if (amount_to_take > self.score_left) { return error.TookPastZero; }

        self.score_left -= amount_to_take;
        
        if (!self.gameWon()) { self.turn ^= 1; }
    }

    fn gameWon(self: NimGame) bool {
        return self.score_left == 0;
    }
};

test NimGame {
const t = std.testing;
    const rules = Rules {
        .max_take = 3,
        .points = 10,
        .winner_takes_last = false,
    };

    var state = NimGame.init(rules);
    
    try t.expectEqual(10, state.score_left);
    try t.expectEqual(0, state.turn);

    try state.makeMove(2);

    try t.expectEqual(8, state.score_left);
    try t.expectEqual(1, state.turn);

    try t.expectError(error.TookMoreThanRulesAllow, state.makeMove(4));
    try t.expectError(error.TookZero, state.makeMove(0));

    try t.expectEqual(8, state.score_left);
    try t.expectEqual(1, state.turn);

    try state.makeMove (3);

    try t.expectEqual(5, state.score_left);
    try t.expectEqual(0, state.turn);

    try state.makeMove (3);

    try t.expectEqual(2, state.score_left);
    try t.expectEqual(1, state.turn);

    try t.expectError(error.TookPastZero, state.makeMove(3));

    try t.expectEqual(2, state.score_left);
    try t.expectEqual(1, state.turn);

    try state.makeMove (2);

    try t.expectEqual(0, state.score_left);
    try t.expectEqual(0, state.turn);
    try t.expect(state.gameWon());

    try t.expectError(error.GameOver, state.makeMove (3));

    try t.expectEqual(0, state.score_left);
    try t.expectEqual(0, state.turn);
    try t.expect(state.gameWon());
}

fn play(
    reader: anytype,
    writer: anytype,
    rules: Rules,
) !void {
    var ai = createAi(rules);
    var game = NimGame.init(rules);

    _ = try writer.write("\n");

    const message = switch (ai.first_goer) {
        .Ai => "I choose to go first.\n",
        .Player => "I think you should go first.\n",
    };
    const ai_turn = ai.first_goer;

    _ = try writer.write(message);

    const winner: WhichPlayer = while(true) {
        std.debug.assert(game.score_left > 0);

        try writer.print("{} points remain.\n", .{game.score_left});
        
        if (game.turn == @intFromEnum(ai_turn)) {
            std.debug.assert(game.score_left > ai.next_target);
            const take = game.score_left - ai.next_target;
            try writer.print("I will take {}.\n", .{take});
            try game.makeMove(take);
            ai.next_target -=
                if (ai.next_target > rules.max_take) rules.max_take + 1
                else 0;  
        } else {
            const p = "How many do you wish to take?";
            const take = try 
                promptIntInRangeInsist(reader, writer, p, 1, rules.max_take);
            try game.makeMove(@truncate(take));
        }

        if (game.gameWon()) { 
            const ai_took_last_turn = @intFromEnum(ai_turn) == game.turn;
            const ai_wins = ai_took_last_turn == rules.winner_takes_last;
            break if (ai_wins) .Ai else .Player;
        }
    };

    const pronoun = ([_][]const u8{ "I", "You" })[@intFromEnum(winner)];
    try writer.print("Game over! {s} win!\n\n", .{pronoun});
}

fn howToPlay(reader: anytype, writer: anytype) !void {
    const message =
        \\Subtraction nim is a game you cannot win, but you must discover that
        \\for yourself. Each game starts with a certain number of points.
        \\Each turn, one player may subtract upto a certain number of points.
        \\Then the next turn, the alternate player may subtract upto that
        \\same number of points.
        \\You may choose to take fewer points if you wish, but you must always
        \\take at least one.
        \\The winner is, by default, the one who takes the last point
        \\(this can be customized in the change rules menu so that taking the
        \\last point makes you lose instead).
        \\
        \\(press enter to see an example game)
        \\
    ;

    _ = try writer.write(message);
    try reader.skipUntilDelimiterOrEof('\n');

    const example_game =
        \\Example, suppose there are 10 points, players may take up to 3, and
        \\the last player to take wins.
        \\  Let player 1 take 2. Now there are 8.
        \\  Then let player 2 take 3. Now there are 5.
        \\  Then let player 1 take 1. Now there are 4.
        \\  Then let player 2 take 3. Now there is 1.
        \\  Then let player 1 take the last point. Player 1 wins.
        \\
        \\Again, in this particular game, you may take from 1 to 3 points.
        \\However, the default game has 20 points and you may take 1 or 2.
        \\If the last-player-to-take-loses rule is used, then in the previous
        \\game, player 2 would have won instead.
        \\
        \\(press enter to return to the main menu)
        \\
    ;

    _ = try writer.write(example_game);
    try reader.skipUntilDelimiterOrEof('\n');

    return;
}

fn printRules( 
    writer: anytype, 
    rules: Rules,
) !void {
    const format =
        \\Current rules:
        \\1. Max amount you can take: {}
        \\2. Score target: {}
        \\3. Taking last point makes you *{s}*.
        \\4. Back to main menu.
        \\
    ;
    const lose_win = 
        ([_][]const u8{ "lose", "win" })
        [@intFromBool(rules.winner_takes_last)]; 
    
    try writer.print(format, .{
        rules.max_take,
        rules.points,
        lose_win
    });
}

fn viewChangeRulesMenu(
    reader: anytype,
    writer: anytype,
    current_rules: Rules,
) !Rules {
    var rules = current_rules;

    return while (true) {
        _ = try writer.write("\n");
        try printRules(writer, rules);

        const prompt = "Choose rule to change or 4 to return.";
        const choice = try 
            promptIntInRangeInsist(reader, writer, prompt, 1, 4);

        switch (choice) {
            1 => {  
                const p = "Change max amount you can take:";
                rules.max_take = @truncate(try 
                    promptIntInRangeInsist(reader, writer, p, 1, 255));
                continue;
            },
            2 => {
                const p = "Change target score to win or lose:";
                rules.points = @truncate(try 
                    promptIntInRangeInsist(reader, writer, p, 1, 255));
                continue;
            },
            3 => {
                const p = 
                    "Does taking the last point make you win (1) or lose (2)?";
                const r = try promptIntInRangeInsist(reader, writer, p, 1, 2);
                rules.winner_takes_last = r == 1;
                continue;
            },
            4 => {
                break rules;
            },
            else => unreachable
        }
    };
}

fn mainMenu(
    reader: anytype,
    writer: anytype,
) !void {
    var rules = Rules {};
    var played_at_least_once = false;

    while (true) {
        const msg =
            \\Welcome to subtraction Nim (not the programming language)!
            \\Are you ready for a game you cannot win?
            \\1. Yes! (start game)
            \\2. How to play
            \\3. View/change ruleset
            \\4. No. (quit)
            \\
        ;

        _ = try writer.write(msg);

        const choice = try 
            promptIntInRangeInsist(reader, writer, "choice:", 1, 4);

        switch (choice) {
            1 => { 
                played_at_least_once = true;
                try play(reader, writer, rules);
            },
            2 => { try howToPlay(reader, writer); },
            3 => { 
                rules = try viewChangeRulesMenu(reader, writer, rules);
                _ = try writer.write("\n");
                continue;
            },
            4 => { 
                const quit_messages = [_][]const u8{
                    "That's understandable.\n",
                    "Thanks for playing!\n",
                };
                _ = try writer.write(
                        quit_messages[@intFromBool(played_at_least_once)]);
                break;
            },
            else => unreachable,
        }
    }
}


pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    
    try mainMenu(stdin, stdout);
}
