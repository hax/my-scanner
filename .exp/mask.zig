const std = @import("std");
const Chunk = @Vector(32, u8);
const Mask = u32;
fn splat(c: u8) Chunk { return @splat(c); }

pub inline fn whitespaceMask(chunk: Chunk) Mask {
    const space = chunk == splat(' ');
    const control = (chunk >= splat('\t')) & (chunk <= splat('\r'));
    return @bitCast(space | control);
}

pub inline fn identPartMask(chunk: Chunk) Mask {
    const lower = (chunk >= splat('a')) & (chunk <= splat('z'));
    const upper = (chunk >= splat('A')) & (chunk <= splat('Z'));
    const digit = (chunk >= splat('0')) & (chunk <= splat('9'));
    const under = chunk == splat('_');
    const dollar = chunk == splat('$');
    return @bitCast(lower | upper | digit | under | dollar);
}

pub fn classifyBlock32(chunk: Chunk) [6]Mask {
    const ws = (chunk == splat(' ')) | ((chunk >= splat('\t')) & (chunk <= splat('\r')));
    const digit = (chunk >= splat('0')) & (chunk <= splat('9'));
    const lower = (chunk >= splat('a')) & (chunk <= splat('z'));
    const upper = (chunk >= splat('A')) & (chunk <= splat('Z'));
    const word = lower | upper | digit | (chunk == splat('_')) | (chunk == splat('$')) | (chunk >= splat(0x80));
    const dot = chunk == splat('.');
    const opch = (chunk == splat('=')) | (chunk == splat('<')) | (chunk == splat('>')) |
        (chunk == splat('+')) | (chunk == splat('-')) | (chunk == splat('*')) |
        (chunk == splat('&')) | (chunk == splat('|')) | (chunk == splat('^')) |
        (chunk == splat('!')) | (chunk == splat('?'));
    const misc = (chunk == splat('#')) | (chunk == splat('\\')) | (chunk >= splat(0x80));
    return .{
        @bitCast(word), @bitCast(ws),   @bitCast(digit),
        @bitCast(dot),  @bitCast(opch), @bitCast(misc),
    };
}

export fn useWs(c: Chunk) Mask { return whitespaceMask(c); }
export fn useIdent(c: Chunk) Mask { return identPartMask(c); }
export fn useCls32(c: Chunk, out: *[6]Mask) void { out.* = classifyBlock32(c); }
