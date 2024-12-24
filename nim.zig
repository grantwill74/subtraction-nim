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
    Player = 0,
    Ai = 1,
};

const RulesError = error {
    MaxTakeIsZero,
    TargetScoreIsZero,
};

const Rules = struct {
    max_take: u8 = 2,
    target_score: u8 = 20,
    winner_takes_last: bool = true,

    fn init(
        max_take: u8,
        target_score: u8,
        winner_takes_last: bool,
    ) RulesError!Rules {
        if (max_take == 0) { return error.MaxTakeIsZero; }
        if (target_score == 0) { return error.TargetScoreIsZero; }

        return .{
            .max_take = max_take,
            .target_score = target_score,
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
                .target_score = 10,
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

fn createAi(self: Rules) AiState {
    std.debug.assert(self.max_take > 0);
    std.debug.assert(self.target_score > 0);

    if (self.target_score == 1 and !self.winner_takes_last) {
        return .{ .first_goer = .Player, .next_target = 1 };
    }

    // if loser takes last, then we want to take the one before last
    const actual_target = 
        if (self.winner_takes_last)
            self.target_score
        else 
            self.target_score - 1;

    // if one can win in one turn, ai will want to go first
    if (self.max_take >= actual_target) {
        return .{ .first_goer = .Ai, .next_target = actual_target};
    }

    // the trick with nim is that you work backwards from the target.
    // so if you need 20 to win and max_take is 2, that means that if you get 
    // 17 you win, because the other person must take 1 or 2, and regardless,
    // 18 means you win and 19 means you win.
    // so then, recursively, we need 14 to get 17. and 11 to get 14.
    // if we take 20 % (max_take = 2 + 1 = 3), we get 2, which means whoever
    // gets two actually wins. therefore, 2 is our target and we can get it
    // if we go first.
    const rem = actual_target % (self.max_take + 1);

    if (rem == 0) {
        return .{ .first_goer = .Player, .next_target = self.max_take + 1 };
    }

    return .{ .first_goer = .Ai, .next_target = rem };
}

test createAi {
    const t = std.testing;
    {
        const default_rules = Rules {};
        const default_expected = AiState {
            .first_goer = .Ai,
            .next_target = 2,
        };

        try t.expectEqual(default_expected, createAi(default_rules));
    }
    {
        const rule = Rules {
            .max_take = 3,
            .target_score = 20,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Player,
            .next_target = 4,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 4,
            .target_score = 20,
            .winner_takes_last = false,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 4,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 3,
            .target_score = 3,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 3,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 2,
            .target_score = 1,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 1,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 2,
            .target_score = 1,
            .winner_takes_last = false,
        };
        const expected = AiState {
            .first_goer = .Player,
            .next_target = 1,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 1,
            .target_score = 10,
            .winner_takes_last = true,
        };
        const expected = AiState {
            .first_goer = .Player,
            .next_target = 2,
        };

        try t.expectEqual(expected, createAi(rule));
    }
    {
        const rule = Rules {
            .max_take = 1,
            .target_score = 10,
            .winner_takes_last = false,
        };
        const expected = AiState {
            .first_goer = .Ai,
            .next_target = 1,
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
            .score_left = rules.target_score,
        };
    }

    fn makeMove(self: *NimGame, amount_to_take: u8) MoveError!void {
        if (self.gameWon()) { return error.GameOver; }
        if (amount_to_take == 0) { return error.TookZero; }
        if (amount_to_take > self.rules.max_take) 
            { return error.TookMoreThanRulesAllow; }
        if (amount_to_take > self.score_left) { return error.TookPastZero; }

        self.score_left -= amount_to_take;
        self.turn ^= 1;
    }

    fn gameWon(self: NimGame) bool {
        return self.score_left == 0;
    }
};

test NimGame {
const t = std.testing;
    const rules = Rules {
        .max_take = 3,
        .target_score = 10,
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

fn howToPlay(reader: anytype, writer: anytype) !void {
    const message =
        \\Nim is a game you cannot win, but you must discover that for yourself.
        \\Each game starts with a certain number of points.
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
        rules.target_score,
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
                rules.target_score = @truncate(try 
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
    var game = NimGame.init(Rules {});
    var played_at_least_once = false;

    while (true) {
        const msg =
            \\Welcome to Nim (not the programming language)!
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
                unreachable; 
            },
            2 => { try howToPlay(reader, writer); },
            3 => { 
                game.rules = try
                    viewChangeRulesMenu(reader, writer, game.rules);
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
