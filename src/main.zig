const r4os = @import("r4os");

pub const op_capabilities: u32 = 1;
pub const op_parse_summary: u32 = 2;
pub const op_layout_summary: u32 = 3;
pub const op_selftest: u32 = 4;

pub const result_ok: i32 = 0;
pub const result_bad_buffer: i32 = -2;
pub const result_unknown_op: i32 = -4;
pub const result_output_small: i32 = -5;
pub const result_malformed: i32 = -6;
pub const result_limit: i32 = -8;
pub const result_busy: i32 = -9;

var protocol_api: ?*const r4os.r4dev.ProtocolApi = null;
var workspace_busy: u8 = 0;
var document_workspace: r4os.html.Document = .{};
var stylesheet_workspace: r4os.css.Stylesheet = .{};
var layout_workspace: r4os.web_layout.Layout = .{};

comptime {
    asm (r4os.r4dev.protocolEntriesAsm("r4css_init", "r4css_shutdown", "r4css_query", "r4css_dispatch"));
}

export fn r4css_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    protocol_api = api;
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    ctx.logInfo("R4CSS.R4P init");
    _ = ctx.registerRole("text.css", .data, 0);
    _ = ctx.setStatus(.active, "CSS cascade and layout active");
    return 0;
}

export fn r4css_shutdown() callconv(.c) i32 {
    document_workspace.reset();
    stylesheet_workspace.reset();
    layout_workspace.reset(.{ .width = 1, .height = 1 });
    protocol_api = null;
    return 0;
}

export fn r4css_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("R4CSS ready"),
    };
    return 0;
}

export fn r4css_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    return switch (op) {
        op_capabilities => writeOut(out_buffer, "role=text.css;selectors=type|class|id|attribute|descendant|child|pseudo;cascade=inherit|variables;layout=block|inline|flex|grid|position;render=structural"),
        op_parse_summary => parseSummary(in_buffer, out_buffer),
        op_layout_summary => layoutSummary(in_buffer, out_buffer),
        op_selftest => selftest(out_buffer),
        else => result_unknown_op,
    };
}

fn parseSummary(in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const input = inputBytes(in_buffer) orelse return result_bad_buffer;
    const stats = stylesheet_workspace.parse(input) catch |err| return cssError(err);
    const out = outputBytes(out_buffer) orelse return result_bad_buffer;
    var len: usize = 0;
    if (!append(out, &len, "rules=") or
        !appendDecimal(out, &len, stats.rules) or
        !append(out, &len, ";declarations=") or
        !appendDecimal(out, &len, stats.declarations) or
        !append(out, &len, ";ignored=") or
        !appendDecimal(out, &len, stats.ignored_rules))
    {
        return result_output_small;
    }
    return finish(out_buffer, len);
}

fn layoutSummary(in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const input = inputBytes(in_buffer) orelse return result_bad_buffer;
    _ = document_workspace.parse(input, .{ .content_type = "text/html;charset=utf-8" }) catch return result_malformed;
    stylesheet_workspace.reset();
    stylesheet_workspace.appendDocumentStyles(&document_workspace) catch |err| return cssError(err);
    const stats = layout_workspace.reflow(&document_workspace, &stylesheet_workspace, .{ .width = 640, .height = 400 }) catch |err| return layoutError(err);
    const out = outputBytes(out_buffer) orelse return result_bad_buffer;
    var len: usize = 0;
    if (!append(out, &len, "ops=") or
        !appendDecimal(out, &len, stats.render_ops) or
        !append(out, &len, ";width=") or
        !appendDecimal(out, &len, @intCast(@max(0, stats.content_width))) or
        !append(out, &len, ";height=") or
        !appendDecimal(out, &len, @intCast(@max(0, stats.content_height))) or
        !append(out, &len, ";hash=") or
        !appendHex(out, &len, stats.structural_hash))
    {
        return result_output_small;
    }
    return finish(out_buffer, len);
}

fn selftest(out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const fixture =
        "<!doctype html><style>:root{--accent:#204080}body{font-family:Terminal}" ++
        ".cards{display:grid;grid-template-columns:repeat(2,1fr);gap:6px}" ++
        ".card{padding:4px;border-width:1px}.card::before{content:'* ';color:var(--accent)}" ++
        "a:link{color:#0000cc;text-decoration:underline}</style><body><h1>Layout</h1>" ++
        "<div class=cards><div class=card>Alpha beta gamma</div><div class=card>" ++
        "<a href=/next>Unicode €</a></div></div></body>";
    _ = document_workspace.parse(fixture, .{ .content_type = "text/html;charset=utf-8" }) catch return result_malformed;
    stylesheet_workspace.reset();
    stylesheet_workspace.appendDocumentStyles(&document_workspace) catch return result_limit;
    if (stylesheet_workspace.rule_count < 4) return result_malformed;
    const narrow = layout_workspace.reflow(&document_workspace, &stylesheet_workspace, .{ .width = 280, .height = 160 }) catch return result_limit;
    const narrow_hash = narrow.structural_hash;
    const wide = layout_workspace.reflow(&document_workspace, &stylesheet_workspace, .{ .width = 640, .height = 300 }) catch return result_limit;
    if (narrow.render_ops < 6 or wide.render_ops < 6 or narrow_hash == wide.structural_hash) return result_malformed;
    return writeOut(out_buffer, "R4CSS selftest: OK parser=ok cascade=ok layout=ok reflow=ok render-list=ok");
}

fn claimWorkspace() bool {
    return @cmpxchgStrong(u8, &workspace_busy, 0, 1, .acquire, .monotonic) == null;
}

fn releaseWorkspace() void {
    @atomicStore(u8, &workspace_busy, 0, .release);
}

fn cssError(err: r4os.css.Error) i32 {
    return switch (err) {
        error.SourceTooLarge, error.RuleLimit, error.DeclarationLimit, error.LayerLimit, error.SelectorLimit => result_limit,
        else => result_malformed,
    };
}

fn layoutError(err: r4os.web_layout.Error) i32 {
    return switch (err) {
        error.RenderLimit, error.TextLimit, error.DepthLimit => result_limit,
    };
}

fn inputBytes(buffer: *const r4os.abi.ProtocolBuffer) ?[]const u8 {
    if (buffer.data == null or buffer.len > buffer.capacity) return null;
    const ptr: [*]const u8 = @ptrCast(buffer.data.?);
    return ptr[0..buffer.len];
}

fn outputBytes(buffer: *r4os.abi.ProtocolBuffer) ?[]u8 {
    if (buffer.data == null) return null;
    const ptr: [*]u8 = @ptrCast(buffer.data.?);
    return ptr[0..buffer.capacity];
}

fn finish(buffer: *r4os.abi.ProtocolBuffer, len: usize) i32 {
    if (len > buffer.capacity) return result_output_small;
    buffer.len = @intCast(len);
    return result_ok;
}

fn writeOut(buffer: *r4os.abi.ProtocolBuffer, value: []const u8) i32 {
    const out = outputBytes(buffer) orelse return result_bad_buffer;
    if (value.len > out.len) return result_output_small;
    if (value.len > 0) @memcpy(out[0..value.len], value);
    return finish(buffer, value.len);
}

fn append(out: []u8, len: *usize, value: []const u8) bool {
    if (value.len > out.len -| len.*) return false;
    if (value.len > 0) @memcpy(out[len.* .. len.* + value.len], value);
    len.* += value.len;
    return true;
}

fn appendDecimal(out: []u8, len: *usize, value: usize) bool {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    if (remaining == 0) return append(out, len, "0");
    while (remaining > 0) : (remaining /= 10) {
        digits[count] = @intCast('0' + remaining % 10);
        count += 1;
    }
    while (count > 0) {
        count -= 1;
        if (!append(out, len, digits[count .. count + 1])) return false;
    }
    return true;
}

fn appendHex(out: []u8, len: *usize, value: u64) bool {
    const digits = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const digit: usize = @intCast((value >> shift) & 0xF);
        if (!append(out, len, digits[digit .. digit + 1])) return false;
        if (shift == 0) break;
        shift -= 4;
    }
    return true;
}

fn note(comptime value: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    const count = @min(value.len, out.len - 1);
    @memcpy(out[0..count], value[0..count]);
    return out;
}
