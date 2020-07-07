const std = @import("std");
const base64 = std.base64;
const ascii = std.ascii;
const time = std.time;
const rand = std.rand;
const fmt = std.fmt;
const mem = std.mem;

const hzzp = @import("hzzp");
const http = std.http;

const Sha1 = std.crypto.Sha1;
const assert = std.debug.assert;

pub usingnamespace @import("events.zig");

fn stripCarriageReturn(buffer: []u8) []u8 {
    if (buffer[buffer.len - 1] == '\r') {
        return buffer[0 .. buffer.len - 1];
    } else {
        return buffer;
    }
}

pub fn create(buffer: []u8, reader: var, writer: var) BaseClient(@TypeOf(reader), @TypeOf(writer)) {
    assert(@typeInfo(@TypeOf(reader)) == .Pointer);
    assert(@typeInfo(@TypeOf(writer)) == .Pointer);
    assert(buffer.len >= 16);

    return BaseClient(@TypeOf(reader), @TypeOf(writer)).init(buffer, reader, writer);
}

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const handshake_key_length = 8;

fn checkHandshakeKey(original: []const u8, recieved: []const u8) bool {
    var hash = Sha1.init();
    hash.update(original);
    hash.update(websocket_guid);

    var hashed_key: [Sha1.digest_length]u8 = undefined;
    hash.final(&hashed_key);

    var encoded: [base64.Base64Encoder.calcSize(Sha1.digest_length)]u8 = undefined;
    base64.standard_encoder.encode(&encoded, &hashed_key);

    return mem.eql(u8, &encoded, recieved);
}

pub fn BaseClient(comptime Reader: type, comptime Writer: type) type {
    const ReaderError = @typeInfo(Reader).Pointer.child.Error;
    const WriterError = @typeInfo(Writer).Pointer.child.Error;

    const HzzpClient = hzzp.BaseClient.BaseClient(Reader, Writer);

    return struct {
        const Self = @This();

        read_buffer: []u8,
        prng: rand.DefaultPrng,

        reader: Reader,
        writer: Writer,

        handshaken: bool = false,

        current_mask: ?u32 = null,
        mask_index: usize = 0,

        chunk_need: usize = 0,
        chunk_read: usize = 0,
        chunk_has_mask: bool = false,
        chunk_mask: [4]u8 = undefined,

        state: ParserState = .header,

        pub fn init(buffer: []u8, reader: Reader, writer: Writer) Self {
            return Self{
                .read_buffer = buffer,
                .prng = rand.DefaultPrng.init(@bitCast(u64, time.milliTimestamp())),
                .reader = reader,
                .writer = writer,
            };
        }

        pub const HandshakeError = ReaderError || WriterError || HzzpClient.ReadError || error{ WrongResponse, InvalidConnectionHeader, FailedChallenge, ConnectionClosed };
        pub fn handshake(self: *Self, headers: *http.Headers, path: []const u8) HandshakeError!void {
            var raw_key: [handshake_key_length]u8 = undefined;
            self.prng.random.bytes(&raw_key);

            var encoded_key: [base64.Base64Encoder.calcSize(handshake_key_length)]u8 = undefined;
            base64.standard_encoder.encode(&encoded_key, &raw_key);

            var client = hzzp.BaseClient.create(self.read_buffer, self.reader, self.writer);
            try client.writeHead("GET", path);

            for (headers.toSlice()) |entry| {
                try client.writeHeader(entry.name, entry.value);
            }

            try client.writeHeader("Connection", "Upgrade");
            try client.writeHeader("Upgrade", "websocket");
            try client.writeHeader("Sec-WebSocket-Version", "13");
            try client.writeHeader("Sec-WebSocket-Key", &encoded_key);
            try client.writeHeadComplete();

            var got_upgrade_header: bool = false;
            var got_accept_header: bool = false;

            while (!client.done) {
                switch (try client.readEvent()) {
                    .status => |etc| {
                        if (etc.code != 101) {
                            return error.WrongResponse;
                        }
                    },
                    .header => |etc| {
                        if (ascii.eqlIgnoreCase(etc.name, "connection")) {
                            got_upgrade_header = true;

                            if (!ascii.eqlIgnoreCase(etc.value, "upgrade")) {
                                return error.InvalidConnectionHeader;
                            }
                        } else if (ascii.eqlIgnoreCase(etc.name, "sec-websocket-accept")) {
                            got_accept_header = true;

                            if (!checkHandshakeKey(&encoded_key, etc.value)) {
                                return error.FailedChallenge;
                            }
                        }
                    },
                    .end => break,
                    .invalid => return error.WrongResponse,
                    .closed => return error.ConnectionClosed,

                    else => {},
                }
            }

            if (!got_upgrade_header) {
                return error.InvalidConnectionHeader;
            } else if (!got_accept_header) {
                return error.FailedChallenge;
            }
        }

        pub fn writeMessageHeader(self: *Self, header: MessageHeader) WriterError!void {
            var bytes: [2]u8 = undefined;
            bytes[0] = @as(u8, header.opcode);
            bytes[1] = 0;

            if (header.fin) bytes[0] |= 0x80;
            if (header.rsv1) bytes[0] |= 0x40;
            if (header.rsv2) bytes[0] |= 0x20;
            if (header.rsv3) bytes[0] |= 0x10;

            if (header.mask) |_| bytes[1] |= 0x80;

            if (header.length < 126) {
                bytes[1] |= @truncate(u8, header.length);
                try self.writer.writeAll(&bytes);
            } else if (header.length < 0x10000) {
                bytes[1] |= 126;
                try self.writer.writeAll(&bytes);

                var len: [2]u8 = undefined;
                mem.writeIntBig(u16, &len, @truncate(u16, header.length));

                try self.writer.writeAll(&len);
            } else {
                bytes[1] |= 127;
                try self.writer.writeAll(&bytes);

                var len: [8]u8 = undefined;
                mem.writeIntBig(u64, &len, header.length);

                try self.writer.writeAll(&len);
            }

            if (header.mask) |mask| {
                try self.writer.writeAll(&mem.toBytes(mask));

                self.current_mask = mask;
                self.mask_index = 0;
            } else {
                self.current_mask = null;
                self.mask_index = 0;
            }
        }

        pub fn writeMessagePayload(self: *Self, payload: []const u8) WriterError!void {
            if (self.current_mask) |mask| {
                unreachable;
            } else {
                try self.writer.writeAll(payload);
            }
        }

        pub fn readEvent(self: *Self) ReaderError!ClientEvent {
            switch (self.state) {
                .header => {
                    var read_len = try self.reader.readAll(self.read_buffer[0..2]);
                    if (read_len != 2) return ClientEvent.closed;

                    var fin = self.read_buffer[0] & 0x80 == 0x80;
                    var rsv1 = self.read_buffer[0] & 0x40 == 0x40;
                    var rsv2 = self.read_buffer[0] & 0x20 == 0x20;
                    var rsv3 = self.read_buffer[0] & 0x10 == 0x10;
                    var opcode = @truncate(u4, self.read_buffer[0]);

                    var masked = self.read_buffer[1] & 0x80 == 0x80;
                    var check_len = @truncate(u7, self.read_buffer[1]);
                    var len: u64 = check_len;

                    var mask_index: u4 = 2;

                    if (check_len == 127) {
                        read_len = try self.reader.readAll(self.read_buffer[2..10]);
                        if (read_len != 8) return ClientEvent.closed;

                        mask_index = 10;
                        len = mem.readIntBig(u64, self.read_buffer[2..10]);


                        self.chunk_need = len;
                        self.chunk_read = 0;
                    } else if (check_len == 126) {
                        read_len = try self.reader.readAll(self.read_buffer[2..4]);
                        if (read_len != 2) return ClientEvent.closed;

                        mask_index = 4;
                        len = mem.readIntBig(u16, self.read_buffer[2..4]);

                        self.chunk_need = len;
                        self.chunk_read = 0;
                    } else {
                        self.chunk_need = check_len;
                        self.chunk_read = 0;
                    }

                    if (masked) {
                        read_len = try self.reader.readAll(self.read_buffer[mask_index .. mask_index + 4]);
                        if (read_len != 4) return ClientEvent.closed;

                        self.chunk_has_mask = true;

                        for (self.read_buffer[mask_index .. mask_index + 4]) |c, i| {
                            self.chunk_mask[i] = c;
                        }
                    } else {
                        self.chunk_has_mask = false;
                    }

                    self.state = .chunk;

                    return ClientEvent{
                        .header = .{
                            .fin = fin,
                            .rsv1 = rsv1,
                            .rsv2 = rsv2,
                            .rsv3 = rsv3,
                            .opcode = opcode,
                            .length = len,
                            // .mask = self.chunk_mask,
                        },
                    };
                },
                .chunk => {
                    var left = self.chunk_need - self.chunk_read;

                    if (left <= self.read_buffer.len) {
                        var read_len = try self.reader.readAll(self.read_buffer[0..left]);
                        if (read_len != left) return ClientEvent.closed;

                        if (self.chunk_has_mask) {
                            for (self.read_buffer[0..read_len]) |*c, i| {
                                c.* = c.* ^ self.chunk_mask[(i + self.chunk_read) % 4];
                            }
                        }

                        self.state = .header;
                        return ClientEvent{
                            .chunk = .{
                                .data = self.read_buffer[0..read_len],
                                .final = true,
                            },
                        };
                    } else {
                        var read_len = try self.reader.read(self.read_buffer);
                        if (read_len == 0) return ClientEvent.closed;

                        if (self.chunk_has_mask) {
                            for (self.read_buffer[0..read_len]) |*c, i| {
                                c.* = c.* ^ self.chunk_mask[(i + self.chunk_read) % 4];
                            }
                        }

                        self.chunk_read += read_len;
                        return ClientEvent{
                            .chunk = .{
                                .data = self.read_buffer[0..read_len],
                            },
                        };
                    }
                },
            }
        }
    };
}

const testing = std.testing;
const io = std.io;

test "decodes a simple message" {
    var read_buffer: [32]u8 = undefined;
    var the_void: [1024]u8 = undefined;
    var response = [_]u8{
        0x82, 0x0d, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f,
        0x72, 0x6c, 0x64, 0x21,
    };

    var reader = io.fixedBufferStream(&response).reader();
    var writer = io.fixedBufferStream(&the_void).writer();

    var client = create(&read_buffer, &reader, &writer);
    client.handshaken = true;

    try client.writeMessageHeader(.{
        .opcode = 2,
        .length = 9,
    });

    try client.writeMessagePayload("aaabbbccc");

    var header = try client.readEvent();
    testing.expect(header == .header);
    testing.expect(header.header.fin == true);
    testing.expect(header.header.rsv1 == false);
    testing.expect(header.header.rsv2 == false);
    testing.expect(header.header.rsv3 == false);
    testing.expect(header.header.opcode == 2);
    testing.expect(header.header.length == 13);
    testing.expect(header.header.mask == null);

    var payload = try client.readEvent();
    testing.expect(payload == .chunk);
    testing.expect(payload.chunk.final == true);
    testing.expect(mem.eql(u8, payload.chunk.data, "Hello, World!"));
}

test "decodes a masked message" {
    var read_buffer: [32]u8 = undefined;
    var the_void: [1024]u8 = undefined;
    var response = [_]u8{
        0x82, 0x8d, 0x12, 0x34, 0x56, 0x78, 0x5a, 0x51, 0x3a, 0x14, 0x7d,
        0x18, 0x76, 0x2f, 0x7d, 0x46, 0x3a, 0x1c, 0x33,
    };

    var reader = io.fixedBufferStream(&response).reader();
    var writer = io.fixedBufferStream(&the_void).writer();

    var client = create(&read_buffer, &reader, &writer);
    client.handshaken = true;

    try client.writeMessageHeader(.{
        .opcode = 2,
        .length = 9,
    });

    try client.writeMessagePayload("aaabbbccc");

    var header = try client.readEvent();
    testing.expect(header == .header);
    testing.expect(header.header.fin == true);
    testing.expect(header.header.rsv1 == false);
    testing.expect(header.header.rsv2 == false);
    testing.expect(header.header.rsv3 == false);
    testing.expect(header.header.opcode == 2);
    testing.expect(header.header.length == 13);
    // testing.expect(header.header.mask != null);

    var payload = try client.readEvent();
    testing.expect(payload == .chunk);
    testing.expect(payload.chunk.final == true);
    testing.expect(mem.eql(u8, payload.chunk.data, "Hello, World!"));
}